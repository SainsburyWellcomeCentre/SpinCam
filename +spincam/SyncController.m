classdef SyncController < handle
    %SYNCCONTROLLER TTL synchronization configuration for Chameleon3-class cameras.
    %   s = spincam.SyncController('passive')
    %   s = spincam.SyncController('triggered', 'TriggerType', 'frame', 'TtlLine', 'Line0')
    %   s = spincam.SyncController('strobe', 'StrobeLine', 'Line1', 'StrobeEveryN', 4)
    %
    %   Modes (aliases A/B/C):
    %     passive   free-run; per-frame TTL state of TtlLine is logged
    %     triggered TriggerType 'frame': each TTL edge exposes one frame;
    %               TriggerType 'start': free-run, recording starts at the first
    %               rising edge on TtlLine (frame-accurate via embedded GPIO)
    %     strobe    StrobeLine outputs StrobeSource (e.g. ExposureActive), optionally
    %               only every N-th frame via the camera's strobe pattern registers;
    %               TtlLine logging continues as in passive mode
    %
    %   plan = s.apply(device) writes nodes/registers (streams must be stopped) and
    %   returns the TTL settings the acquisition engine needs.

    properties
        Mode (1,:) char = 'passive'
        % TtlLine/StrobeLine accept 'Line2', "Line2" or 2; set methods validate.
        TtlLine = 'Line0'
        TtlSource (1,:) char = 'embedded'
        EmbedFrameCounter (1,1) logical = true
        TriggerType (1,:) char = 'frame'
        TriggerActivation (1,:) char = 'RisingEdge'
        ExposureMode (1,:) char = 'Timed'
        TriggerDelay_us (1,1) double {mustBeNonnegative} = 0
        StrobeLine = 'Line1'
        StrobeSource (1,:) char = 'ExposureActive'
        StrobeDuration_us (1,1) double {mustBeNonnegative} = 0
        StrobeDelay_us (1,1) double {mustBeNonnegative} = 0
        StrobeInvert (1,1) logical = false
        StrobeEveryN (1,1) double {mustBeInteger, mustBeInRange(StrobeEveryN, 1, 16)} = 1
    end

    methods
        function obj = SyncController(varargin)
            args = varargin;
            if mod(numel(args), 2) == 1
                obj.Mode = args{1};
                args = args(2:end);
            end
            names = properties(obj);
            for k = 1:2:numel(args)
                match = names(strcmpi(names, args{k}));
                if isempty(match)
                    error('spincam:sync:unknownOption', 'Unknown SyncController option "%s". Valid: %s.', ...
                        char(args{k}), strjoin(names, ', '));
                end
                obj.(match{1}) = args{k + 1};
            end
        end

        function set.Mode(obj, value)
            value = lower(char(value));
            aliases = struct('a', 'passive', 'b', 'triggered', 'c', 'strobe');
            if isfield(aliases, value)
                value = aliases.(value);
            end
            obj.Mode = mustBeOneOf(value, {'passive', 'triggered', 'strobe'}, 'Mode');
        end

        function set.TtlLine(obj, value)
            obj.TtlLine = mustBeOneOf(canonicalLine(value), {'Line0', 'Line1', 'Line2', 'Line3'}, 'TtlLine');
        end

        function set.StrobeLine(obj, value)
            obj.StrobeLine = mustBeOneOf(canonicalLine(value), {'Line1', 'Line2', 'Line3'}, 'StrobeLine');
        end

        function set.TtlSource(obj, value)
            obj.TtlSource = mustBeOneOf(lower(char(value)), {'embedded', 'polled', 'none'}, 'TtlSource');
        end

        function set.TriggerType(obj, value)
            obj.TriggerType = mustBeOneOf(lower(char(value)), {'frame', 'start'}, 'TriggerType');
        end

        function set.TriggerActivation(obj, value)
            obj.TriggerActivation = mustBeOneOf(char(value), {'RisingEdge', 'FallingEdge'}, 'TriggerActivation');
        end

        function set.ExposureMode(obj, value)
            obj.ExposureMode = mustBeOneOf(char(value), {'Timed', 'TriggerWidth'}, 'ExposureMode');
        end

        function idx = ttlLineIndex(obj)
            idx = str2double(obj.TtlLine(end));
        end

        function tf = usesTtlInput(obj)
            tf = ~strcmp(obj.TtlSource, 'none') || strcmp(obj.Mode, 'triggered');
        end

        function gate = recordGate(obj)
            if strcmp(obj.Mode, 'triggered') && strcmp(obj.TriggerType, 'start')
                gate = 'firstRisingEdge';
            else
                gate = 'none';
            end
        end

        function txt = describe(obj)
            switch obj.Mode
                case 'passive'
                    txt = sprintf('A passive: log %s (%s)', obj.TtlLine, obj.TtlSource);
                case 'triggered'
                    txt = sprintf('B triggered-%s on %s %s', obj.TriggerType, obj.TtlLine, obj.TriggerActivation);
                case 'strobe'
                    txt = sprintf('C strobe %s=%s every %d; log %s', obj.StrobeLine, obj.StrobeSource, ...
                        obj.StrobeEveryN, obj.TtlLine);
            end
        end

        function validate(obj, device)
            %VALIDATE Throw spincam:sync:* errors for configurations the camera cannot do.
            nm = device.NodeMap;
            if obj.usesTtlInput()
                modes = lineEntries(nm, obj.TtlLine, 'LineMode');
                if ~any(strcmp(modes, 'Input'))
                    error('spincam:sync:lineNotInput', '%s cannot be used as an input on camera %s (LineMode: %s).', ...
                        obj.TtlLine, device.Serial, strjoin(modes, '|'));
                end
            end
            switch obj.Mode
                case 'triggered'
                    sources = nm.info('TriggerSource').Entries;
                    if ~any(strcmp(sources, obj.TtlLine))
                        error('spincam:sync:badTriggerSource', '%s is not a trigger source on camera %s (%s).', ...
                            obj.TtlLine, device.Serial, strjoin(sources, '|'));
                    end
                    if strcmp(obj.TriggerType, 'start') && strcmp(obj.TtlSource, 'none')
                        error('spincam:sync:gateNeedsTtl', ...
                            'TriggerType ''start'' needs TtlSource ''embedded'' or ''polled''.');
                    end
                    if nm.has('ExposureMode')
                        modes = nm.info('ExposureMode').Entries;
                        if ~any(strcmp(modes, obj.ExposureMode))
                            error('spincam:sync:badExposureMode', 'ExposureMode %s is not supported (%s).', ...
                                obj.ExposureMode, strjoin(modes, '|'));
                        end
                    end
                case 'strobe'
                    if strcmp(obj.StrobeLine, obj.TtlLine) && ~strcmp(obj.TtlSource, 'none')
                        error('spincam:sync:lineConflict', ...
                            'StrobeLine and TtlLine are both %s; choose different lines or set TtlSource ''none''.', ...
                            obj.StrobeLine);
                    end
                    modes = lineEntries(nm, obj.StrobeLine, 'LineMode');
                    if ~any(strcmp(modes, 'Output'))
                        error('spincam:sync:lineNotOutput', '%s cannot be used as an output on camera %s (LineMode: %s).', ...
                            obj.StrobeLine, device.Serial, strjoin(modes, '|'));
                    end
                    if obj.StrobeEveryN > 1
                        ctrl = tryRead(device.Registers, spincam.internal.StrobePattern.CtrlOffset);
                        if isempty(ctrl) || ~spincam.internal.StrobePattern.isPresent(ctrl)
                            error('spincam:sync:noStrobePattern', ...
                                'Camera %s has no strobe pattern register; StrobeEveryN must be 1.', device.Serial);
                        end
                    end
            end
        end

        function plan = apply(obj, device)
            %APPLY Configure DEVICE for this sync mode. Streams must be stopped.
            if device.isStreaming()
                error('spincam:sync:streaming', 'Stop streaming on camera %s before applying sync settings.', ...
                    device.Serial);
            end
            obj.validate(device);
            nm = device.NodeMap;

            % Trigger mode stays Off while trigger/line nodes are reconfigured.
            nm.setIfDifferent('TriggerMode', 'Off');
            if obj.usesTtlInput()
                selectLine(nm, obj.TtlLine);
                if nm.isWritable('LineMode')
                    nm.setIfDifferent('LineMode', 'Input');
                end
            end

            switch obj.Mode
                case 'triggered'
                    obj.applyTrigger(nm);
                case 'strobe'
                    obj.applyStrobeLine(nm, device);
            end

            obj.applyStrobePattern(device);
            plan = obj.applyEmbedding(device);
            plan.Mode = obj.Mode;
            plan.Gate = obj.recordGate();
            device.setSyncPlan(plan);
        end
    end

    methods (Static)
        function names = optionsFor(mode, ttlSource)
            %OPTIONSFOR Options that take effect in MODE (others are ignored by apply).
            %   With TTLSOURCE 'none', TtlLine is only used in 'triggered' mode.
            arguments
                mode {mustBeTextScalar}
                ttlSource {mustBeTextScalar} = 'embedded'
            end
            mode = spincam.SyncController(char(mode)).Mode;
            names = {'Mode', 'TtlSource', 'TtlLine', 'EmbedFrameCounter'};
            if strcmpi(ttlSource, 'none') && ~strcmp(mode, 'triggered')
                names = setdiff(names, {'TtlLine'}, 'stable');
            end
            switch mode
                case 'triggered'
                    names = [names, {'TriggerType', 'TriggerActivation', 'ExposureMode', 'TriggerDelay_us'}];
                case 'strobe'
                    names = [names, {'StrobeLine', 'StrobeSource', 'StrobeEveryN', 'StrobeDuration_us', ...
                        'StrobeDelay_us', 'StrobeInvert'}];
            end
        end

        function reset(device)
            %RESET Free-run, strobe pattern period 1, embedding off, Line2/3 back to inputs.
            if device.isStreaming()
                error('spincam:sync:streaming', 'Stop streaming on camera %s before resetting sync.', device.Serial);
            end
            nm = device.NodeMap;
            nm.setIfDifferent('TriggerMode', 'Off');
            original = nm.get('LineSelector');
            for line = {'Line2', 'Line3'}
                if any(strcmp(nm.info('LineSelector').Entries, line{1}))
                    nm.setIfDifferent('LineSelector', line{1});
                    if nm.isWritable('LineMode') && strcmp(nm.get('LineMode'), 'Output')
                        nm.set('LineMode', 'Input');
                    end
                end
            end
            nm.setIfDifferent('LineSelector', original);

            reg = device.Registers;
            F = spincam.internal.FrameInfo;
            fi = tryRead(reg, F.RegisterOffset);
            if ~isempty(fi) && F.isPresent(fi) && F.configure(fi, {}) ~= fi
                reg.write(F.RegisterOffset, F.configure(fi, {}));
            end
            P = spincam.internal.StrobePattern;
            ctrl = tryRead(reg, P.CtrlOffset);
            if ~isempty(ctrl) && P.isPresent(ctrl)
                if P.period(ctrl) ~= 1
                    reg.write(P.CtrlOffset, P.setPeriod(ctrl, 1));
                end
                for k = 0:3
                    m = tryRead(reg, P.maskOffset(k));
                    if ~isempty(m) && P.setMaskSlots(m, 0:15) ~= m
                        reg.write(P.maskOffset(k), P.setMaskSlots(m, 0:15));
                    end
                end
            end
            device.setSyncPlan(spincam.CameraDevice.defaultPlan());
        end
    end

    methods (Access = private)
        function applyTrigger(obj, nm)
            if nm.has('TriggerSelector')
                nm.setIfDifferent('TriggerSelector', 'FrameStart');
            end
            nm.setIfDifferent('TriggerSource', obj.TtlLine);
            nm.setIfDifferent('TriggerActivation', obj.TriggerActivation);
            if nm.has('ExposureMode')
                nm.setIfDifferent('ExposureMode', obj.ExposureMode);
            end
            if nm.has('TriggerDelayEnabled')
                nm.setIfDifferent('TriggerDelayEnabled', obj.TriggerDelay_us > 0);
            end
            if obj.TriggerDelay_us > 0
                nm.set('TriggerDelay', obj.TriggerDelay_us);
            end
            if strcmp(obj.TriggerType, 'frame')
                nm.set('TriggerMode', 'On');
            end
        end

        function applyStrobeLine(obj, nm, device)
            selectLine(nm, obj.StrobeLine);
            if nm.isWritable('LineMode')
                nm.setIfDifferent('LineMode', 'Output');
            end
            sources = nm.info('LineSource').Entries;
            if ~any(strcmp(sources, obj.StrobeSource))
                error('spincam:sync:badStrobeSource', '%s on camera %s supports LineSource %s, not %s.', ...
                    obj.StrobeLine, device.Serial, strjoin(sources, '|'), obj.StrobeSource);
            end
            nm.setIfDifferent('LineSource', obj.StrobeSource);
            if nm.has('LineInverter') && nm.isWritable('LineInverter')
                nm.setIfDifferent('LineInverter', obj.StrobeInvert);
            end
            if nm.has('StrobeDuration') && nm.isWritable('StrobeDuration')
                nm.setIfDifferent('StrobeDuration', obj.StrobeDuration_us);
            end
            if nm.has('StrobeDelay') && nm.isWritable('StrobeDelay')
                nm.setIfDifferent('StrobeDelay', obj.StrobeDelay_us);
            end
        end

        function applyStrobePattern(obj, device)
            P = spincam.internal.StrobePattern;
            reg = device.Registers;
            ctrl = tryRead(reg, P.CtrlOffset);
            if isempty(ctrl) || ~P.isPresent(ctrl)
                return
            end
            n = 1;
            if strcmp(obj.Mode, 'strobe')
                n = obj.StrobeEveryN;
            end
            if P.period(ctrl) ~= n
                reg.write(P.CtrlOffset, P.setPeriod(ctrl, n));
            end
            if strcmp(obj.Mode, 'strobe')
                offset = P.maskOffset(str2double(obj.StrobeLine(end)));
                mask = reg.read(offset);
                if n > 1
                    wanted = P.setMaskSlots(mask, 0);
                else
                    wanted = P.setMaskSlots(mask, 0:15);
                end
                if wanted ~= mask
                    reg.write(offset, wanted);
                end
            end
        end

        function plan = applyEmbedding(obj, device)
            F = spincam.internal.FrameInfo;
            plan = spincam.CameraDevice.defaultPlan();
            plan.TtlLine = obj.ttlLineIndex();
            plan.TtlSource = obj.TtlSource;
            reg = device.Registers;
            fi = tryRead(reg, F.RegisterOffset);
            if isempty(fi) || ~F.isPresent(fi)
                if strcmp(obj.TtlSource, 'embedded')
                    warning('spincam:sync:embeddedUnavailable', ...
                        'Camera %s has no FRAME_INFO register; using polled TTL sampling.', device.Serial);
                    plan.TtlSource = 'polled';
                end
                return
            end
            fields = {};
            if obj.EmbedFrameCounter && F.isSupported(fi, 'FrameCounter')
                fields{end + 1} = 'FrameCounter';
            end
            if strcmp(obj.TtlSource, 'embedded')
                if F.isSupported(fi, 'GPIO')
                    fields{end + 1} = 'GPIO';
                else
                    warning('spincam:sync:embeddedUnavailable', ...
                        'Camera %s cannot embed GPIO state; using polled TTL sampling.', device.Serial);
                    plan.TtlSource = 'polled';
                end
            end
            wanted = F.configure(fi, fields);
            if wanted ~= fi
                reg.write(F.RegisterOffset, wanted);
            end
            actual = reg.read(F.RegisterOffset);
            if actual ~= wanted
                error('spincam:sync:registerMismatch', ...
                    'FRAME_INFO on camera %s reads 0x%08X after writing 0x%08X.', device.Serial, actual, wanted);
            end
            plan.FrameCounterOffset = F.byteOffset(actual, 'FrameCounter');
            plan.GpioOffset = F.byteOffset(actual, 'GPIO');
        end
    end
end

function value = mustBeOneOf(value, allowed, name)
match = allowed(strcmpi(allowed, value));
if isempty(match)
    error('spincam:sync:badValue', '%s must be one of: %s (got "%s").', name, strjoin(allowed, ', '), value);
end
value = match{1};
end

function line = canonicalLine(value)
if isnumeric(value)
    line = sprintf('Line%d', value);
else
    line = char(value);
    if ~isempty(regexp(line, '^\d$', 'once'))
        line = ['Line' line];
    end
end
end

function selectLine(nm, line)
nm.setIfDifferent('LineSelector', line);
end

function entries = lineEntries(nm, line, nodeName)
lines = nm.info('LineSelector').Entries;
if ~any(strcmp(lines, line))
    entries = {};
    return
end
original = nm.get('LineSelector');
nm.setIfDifferent('LineSelector', line);
restore = onCleanup(@() nm.setIfDifferent('LineSelector', original));
entries = nm.info(nodeName).Entries;
end

function v = tryRead(reg, offset)
try
    v = reg.read(offset);
catch
    v = [];
end
end
