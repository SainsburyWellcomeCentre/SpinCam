classdef CameraDevice < handle
    %CAMERADEVICE One camera: identity, property control and its acquisition stream.
    %   Obtain devices from spincam.CameraManager (cm.camera(serialOrIndex)).
    %
    %   cam.set('ExposureTime', 4000)   switches ExposureAuto off, clamps to limits,
    %                                   returns the value read back
    %   cam.get('FrameRate')
    %   cam.describeProperties()        table of friendly properties
    %   s = cam.getSettings(); cam.applySettings(s)
    %
    %   Friendly names are defined in spincam.internal.PropertyRegistry; any other
    %   name is used as a raw GenICam node name.

    properties
        %SCRUBEMBEDDEDPIXELS Restore the embedded-data pixels in saved/previewed frames.
        ScrubEmbeddedPixels (1,1) logical = true
    end

    properties (SetAccess = {?spincam.CameraManager})
        %NAME File-name prefix such as 'topview' (set with CameraManager.setCameraName).
        Name char = ''
    end

    properties (SetAccess = private)
        Serial char = ''
        Model char = ''
        Firmware char = ''
        IsMock logical = false
        NodeMap
        StreamNodeMap
        Registers
        %STREAM SpinCam.CameraStream (.NET) or [] when no engine is available.
        Stream = []
        %SYNCPLAN TTL/embedding settings last applied by spincam.SyncController.
        SyncPlan struct = spincam.CameraDevice.defaultPlan()
    end

    properties (Dependent)
        SyntheticSource   % SpinCam.SyntheticFrameSource for mock devices ([] otherwise)
    end

    properties (Access = private)
        Source = []
    end

    methods
        function obj = CameraDevice(serial, nodeMap, streamNodeMap, registers, source, isMock)
            obj.Serial = char(serial);
            obj.NodeMap = nodeMap;
            obj.StreamNodeMap = streamNodeMap;
            obj.Registers = registers;
            obj.Source = source;
            obj.IsMock = isMock;
            obj.Model = readOr(nodeMap, 'DeviceModelName', '');
            obj.Firmware = readOr(nodeMap, 'DeviceFirmwareVersion', '');
            if ~isempty(source)
                obj.Stream = SpinCam.CameraStream(source);
            end
        end

        function src = get.SyntheticSource(obj)
            src = [];
            if obj.IsMock
                src = obj.Source;
            end
        end

        % ----------------------------------------------------------------- properties
        function v = get(obj, name)
            [node, ~] = obj.resolve(name);
            v = obj.NodeMap.get(node);
        end

        function actual = set(obj, name, value)
            [node, def] = obj.resolve(name);
            label = char(name);
            if ~isempty(def)
                label = def.Name;
                if def.RequiresStopped && obj.isStreaming()
                    error('spincam:property:streaming', ...
                        '%s can only be changed while camera %s is not streaming.', label, obj.Serial);
                end
            end
            nm = obj.NodeMap;
            before = nm.info(node);
            if ~before.Available
                error('spincam:property:unavailable', ...
                    'Property %s (node %s) is not available on camera %s.', label, node, obj.Serial);
            end
            if ~isempty(def) && (isnumeric(value) || islogical(value)) && ~strcmp(before.Type, 'enum')
                for k = 1:numel(def.EnableNodes)
                    if nm.has(def.EnableNodes{k}) && nm.isWritable(def.EnableNodes{k})
                        nm.setIfDifferent(def.EnableNodes{k}, true);
                    end
                end
                for k = 1:numel(def.AutoNodes)
                    autoNode = def.AutoNodes{k};
                    if nm.has(autoNode) && nm.isWritable(autoNode) && ~strcmp(nm.get(autoNode), 'Off')
                        nm.set(autoNode, 'Off');
                    end
                end
            end
            info = nm.info(node);
            if ~info.Writable
                error('spincam:property:notWritable', ...
                    'Property %s (node %s) is not writable on camera %s.', label, node, obj.Serial);
            end
            value = spincam.CameraDevice.coerce(info, value, label);
            nm.set(node, value);
            actual = nm.get(node);
        end

        function T = describeProperties(obj)
            %DESCRIBEPROPERTIES Table of friendly properties and their current limits.
            defs = spincam.internal.PropertyRegistry.all();
            n = numel(defs);
            Name = cell(n, 1); Node = cell(n, 1); Value = cell(n, 1); Min = nan(n, 1);
            Max = nan(n, 1); Unit = cell(n, 1); Available = false(n, 1); Writable = false(n, 1);
            Auto = cell(n, 1);
            for k = 1:n
                d = defs(k);
                Name{k} = d.Name;
                Unit{k} = d.Unit;
                Auto{k} = '';
                node = obj.NodeMap.firstExisting(d.Nodes);
                Node{k} = node;
                if isempty(node)
                    continue
                end
                s = obj.NodeMap.info(node);
                Value{k} = s.Value;
                Available(k) = s.Available;
                Writable(k) = s.Writable;
                if ~isempty(s.Min), Min(k) = s.Min; end
                if ~isempty(s.Max), Max(k) = s.Max; end
                autoNode = obj.NodeMap.firstExisting(d.AutoNodes);
                if ~isempty(autoNode) && obj.NodeMap.isReadable(autoNode)
                    Auto{k} = obj.NodeMap.get(autoNode);
                end
            end
            T = table(Name, Node, Value, Min, Max, Unit, Available, Writable, Auto);
        end

        function s = getSettings(obj)
            %GETSETTINGS Struct of readable friendly properties (for applySettings).
            names = {'PixelFormat', 'Width', 'Height', 'OffsetX', 'OffsetY', 'FrameRateAuto', ...
                'FrameRate', 'ExposureAuto', 'ExposureTime', 'GainAuto', 'Gain', 'BlackLevel', 'Gamma'};
            s = struct();
            for k = 1:numel(names)
                d = spincam.internal.PropertyRegistry.lookup(names{k});
                node = obj.NodeMap.firstExisting(d.Nodes);
                if ~isempty(node) && obj.NodeMap.isReadable(node)
                    s.(names{k}) = obj.NodeMap.get(node);
                end
            end
        end

        function applySettings(obj, s)
            %APPLYSETTINGS Apply a struct from getSettings. Numeric values whose
            %   auto mode is not 'Off' in S are skipped; auto modes are applied last.
            arguments
                obj
                s (1,1) struct
            end
            autoFor = struct('FrameRate', 'FrameRateAuto', 'ExposureTime', 'ExposureAuto', 'Gain', 'GainAuto');
            if isfield(s, 'PixelFormat')
                obj.set('PixelFormat', s.PixelFormat);
            end
            if all(isfield(s, {'OffsetX', 'OffsetY', 'Width', 'Height'}))
                % setRoi orders offsets and size so any crop can replace any other.
                obj.setRoi([s.OffsetX, s.OffsetY, s.Width, s.Height]);
            end
            order = {};
            exposureFirst = isfield(s, 'ExposureTime') && obj.NodeMap.isReadable('ExposureTime') && ...
                s.ExposureTime < obj.NodeMap.get('ExposureTime');
            if exposureFirst
                order = [order, {'ExposureTime', 'FrameRate'}];
            else
                order = [order, {'FrameRate', 'ExposureTime'}];
            end
            order = [order, {'Gain', 'BlackLevel', 'Gamma', 'FrameRateAuto', 'ExposureAuto', 'GainAuto'}];
            for k = 1:numel(order)
                name = order{k};
                if ~isfield(s, name)
                    continue
                end
                if isfield(autoFor, name) && isfield(s, autoFor.(name)) && ~strcmpi(s.(autoFor.(name)), 'Off')
                    continue
                end
                if strcmp(name, 'Gamma') && ~obj.NodeMap.isAvailable('Gamma')
                    continue
                end
                if strcmp(name, 'FrameRate')
                    obj.restoreFrameRate(s.FrameRate);
                else
                    obj.set(name, s.(name));
                end
            end
        end

        % ------------------------------------------------------------------ crop (ROI)
        function roi = getRoi(obj)
            %GETROI Current crop [x y width height] in sensor pixels (x, y = 0-based offsets).
            nm = obj.NodeMap;
            roi = [nm.get('OffsetX'), nm.get('OffsetY'), nm.get('Width'), nm.get('Height')];
        end

        function sz = sensorSize(obj)
            %SENSORSIZE Full-frame [width height].
            nm = obj.NodeMap;
            if nm.isReadable('SensorWidth') && nm.isReadable('SensorHeight')
                sz = [nm.get('SensorWidth'), nm.get('SensorHeight')];
            elseif nm.isReadable('WidthMax') && nm.isReadable('HeightMax')
                sz = [nm.get('WidthMax'), nm.get('HeightMax')];
            else
                sz = [nm.info('Width').Max + nm.get('OffsetX'), nm.info('Height').Max + nm.get('OffsetY')];
            end
        end

        function actual = setRoi(obj, roi, opts)
            %SETROI Crop the sensor to ROI = [x y width height] (x, y = 0-based offsets).
            %   Width/height are rounded down to the camera's increments and the crop is kept
            %   inside the sensor (warning spincam:roi:adjusted when the result differs).
            %   'Center', true centres the crop and ignores x, y. Streams must be stopped.
            %   Returns the crop read back from the camera.
            arguments
                obj
                roi (1,4) double {mustBeNonnegative}
                opts.Center (1,1) logical = false
            end
            if obj.isStreaming()
                error('spincam:roi:streaming', 'Stop streaming on camera %s before changing the crop.', obj.Serial);
            end
            nm = obj.NodeMap;
            full = obj.sensorSize();
            % Offsets go to 0 first: Width/Height maxima shrink while an offset is set.
            nm.setIfDifferent('OffsetX', 0);
            nm.setIfDifferent('OffsetY', 0);
            w = alignDown(roi(3), nm.info('Width'), full(1));
            h = alignDown(roi(4), nm.info('Height'), full(2));
            nm.setIfDifferent('Width', w);
            nm.setIfDifferent('Height', h);
            if opts.Center
                xy = (full - [w h]) / 2;
            else
                xy = roi(1:2);
            end
            nm.setIfDifferent('OffsetX', alignDown(xy(1), nm.info('OffsetX'), full(1) - w));
            nm.setIfDifferent('OffsetY', alignDown(xy(2), nm.info('OffsetY'), full(2) - h));
            actual = obj.getRoi();
            changed = ~isequal(actual(3:4), roi(3:4)) || (~opts.Center && ~isequal(actual(1:2), roi(1:2)));
            if changed
                warning('spincam:roi:adjusted', 'Camera %s: crop %s adjusted to %s (sensor %dx%d, camera increments).', ...
                    obj.Serial, mat2str(roi), mat2str(actual), full(1), full(2));
            end
        end

        function actual = resetRoi(obj)
            %RESETROI Full frame.
            actual = obj.setRoi([0 0 obj.sensorSize()]);
        end

        % ------------------------------------------------------------------ streaming
        function tf = isStreaming(obj)
            tf = ~isempty(obj.Stream) && obj.Stream.IsRunning;
        end

        function startStream(obj, previewMaxHz)
            arguments
                obj
                previewMaxHz (1,1) double {mustBeNonnegative} = 30
            end
            obj.requireStream();
            if obj.isStreaming()
                return
            end
            if obj.NodeMap.has('PixelFormat')
                pf = obj.NodeMap.get('PixelFormat');
                if ~strcmp(pf, 'Mono8')
                    error('spincam:stream:pixelFormat', ...
                        'Camera %s is set to %s; set PixelFormat to Mono8 before streaming.', obj.Serial, pf);
                end
            end
            plan = obj.SyncPlan;
            s = obj.Stream;
            s.TtlLine = int32(plan.TtlLine);
            s.TtlMode = spincam.CameraDevice.netTtlSource(plan.TtlSource);
            s.EmbeddedFrameCounterOffset = int32(plan.FrameCounterOffset);
            s.EmbeddedGpioOffset = int32(plan.GpioOffset);
            s.ScrubEmbeddedPixels = obj.ScrubEmbeddedPixels;
            s.PreviewMaxHz = previewMaxHz;
            if obj.IsMock
                obj.syncMockSource();
                obj.NodeMap.setRaw('TLParamsLocked', 1);
            else
                obj.configureHostBuffers();
            end
            try
                s.Start();
            catch me
                if obj.IsMock
                    obj.NodeMap.setRaw('TLParamsLocked', 0);
                end
                error('spincam:stream:startFailed', 'Starting camera %s failed: %s', obj.Serial, ...
                    strtok(me.message, newline));
            end
        end

        function stopStream(obj)
            if isempty(obj.Stream)
                return
            end
            obj.Stream.Stop();
            if obj.IsMock
                obj.NodeMap.setRaw('TLParamsLocked', 0);
            end
        end

        function startRecording(obj, options)
            obj.requireStream();
            try
                obj.Stream.StartRecording(options);
            catch me
                error('spincam:stream:recordFailed', 'Starting recording on camera %s failed: %s', ...
                    obj.Serial, strtok(me.message, newline));
            end
        end

        function beginStopRecording(obj)
            if ~isempty(obj.Stream)
                obj.Stream.BeginStopRecording();
            end
        end

        function summary = endStopRecording(obj, timeoutSeconds)
            summary = struct();
            if ~isempty(obj.Stream)
                summary = jsondecode(char(obj.Stream.EndStopRecording(int32(round(timeoutSeconds * 1000)))));
            end
        end

        function s = stats(obj)
            obj.requireStream();
            s = jsondecode(char(obj.Stream.GetStatsJson()));
        end

        function [img, meta] = latestFrame(obj)
            %LATESTFRAME Most recent preview frame (H-by-W uint8) and its metadata.
            obj.requireStream();
            [data, width, height, frameId, ttl, sequence] = obj.Stream.GetLatestFrame();
            meta = struct('Serial', obj.Serial, 'FrameId', double(frameId), 'TTL', double(ttl), ...
                'Width', double(width), 'Height', double(height), 'Sequence', double(sequence));
            if data.Length == 0
                img = zeros(0, 0, 'uint8');
                return
            end
            img = reshape(uint8(data), double(width), double(height))';
        end

        function setSyncPlan(obj, plan)
            %SETSYNCPLAN Record the TTL/embedding plan (called by SyncController.apply).
            obj.SyncPlan = plan;
        end

        function detach(obj)
            %DETACH Stop and release the acquisition stream (camera handle stays open).
            if ~isempty(obj.Stream)
                try
                    obj.Stream.Stop();
                    obj.Stream.Dispose();
                catch me
                    warning('spincam:stream:stopFailed', 'Stopping camera %s: %s', obj.Serial, me.message);
                end
            end
            if ~isempty(obj.Source)
                try
                    obj.Source.Dispose();
                catch
                end
            end
            obj.Stream = [];
            obj.Source = [];
        end

        function delete(obj)
            obj.detach();
        end
    end

    methods (Access = private)
        function restoreFrameRate(obj, target)
            %RESTOREFRAMERATE Make FrameRate read back TARGET (a value read from the camera).
            %   The CM3 quantizes AcquisitionFrameRate, and writing a read-back value can land
            %   one step higher (100.0582 -> 100.1222), so a plain write drifts a snapshot on
            %   every restore. The write -> read-back map is monotonic: bisect the written value.
            actual = obj.set('FrameRate', target);
            tol = 1e-6 * abs(target);
            if abs(actual - target) <= tol
                return
            end
            nm = obj.NodeMap;
            node = obj.resolve('FrameRate');
            limits = nm.info(node);
            side = sign(actual - target);       % side of TARGET that writing TARGET lands on
            gap = abs(actual - target);
            best = [target, actual];
            near = target;                      % a write that reads back on SIDE
            far = target;
            crossed = false;
            for k = 0:10
                far = min(max(target - side * gap * 2^k, limits.Min), limits.Max);
                nm.set(node, far);
                value = nm.get(node);
                if abs(value - target) < abs(best(2) - target)
                    best = [far, value];
                end
                if sign(value - target) ~= side
                    crossed = true;
                    break
                end
                near = far;
            end
            while crossed && abs(best(2) - target) > tol && abs(far - near) > 1e-9 * abs(target)
                mid = (near + far) / 2;
                nm.set(node, mid);
                value = nm.get(node);
                if abs(value - target) < abs(best(2) - target)
                    best = [mid, value];
                end
                if sign(value - target) == side
                    near = mid;
                else
                    far = mid;
                end
            end
            nm.set(node, best(1));
        end

        function [node, def] = resolve(obj, name)
            def = spincam.internal.PropertyRegistry.lookup(name);
            if isempty(def)
                node = char(name);
                if ~obj.NodeMap.has(node)
                    error('spincam:property:unknown', 'Camera %s has no property or node named %s.', ...
                        obj.Serial, node);
                end
                return
            end
            node = obj.NodeMap.firstExisting(def.Nodes);
            if isempty(node)
                error('spincam:property:unsupported', 'Camera %s does not support %s.', obj.Serial, def.Name);
            end
        end

        function requireStream(obj)
            if isempty(obj.Stream)
                error('spincam:stream:unavailable', ...
                    'Camera %s has no acquisition engine (see spincam.setup).', obj.Serial);
            end
        end

        function syncMockSource(obj)
            F = spincam.internal.FrameInfo;
            src = obj.Source;
            width = obj.NodeMap.rawValue('Width');
            height = obj.NodeMap.rawValue('Height');
            if double(src.Width) ~= width || double(src.Height) ~= height
                src.Resize(int32(width), int32(height));   % follow the crop
            end
            src.FrameRate = obj.NodeMap.rawValue('AcquisitionFrameRate');
            frameInfo = obj.Registers.read(F.RegisterOffset);
            src.EmbedFrameCounter = F.byteOffset(frameInfo, 'FrameCounter') >= 0;
            src.EmbedGpio = F.byteOffset(frameInfo, 'GPIO') >= 0;
            src.TtlLine = int32(obj.SyncPlan.TtlLine);
        end

        function configureHostBuffers(obj)
            sn = obj.StreamNodeMap;
            try
                if sn.has('StreamBufferHandlingMode')
                    sn.setIfDifferent('StreamBufferHandlingMode', 'OldestFirst');
                end
                if sn.has('StreamBufferCountMode') && sn.isWritable('StreamBufferCountMode')
                    sn.setIfDifferent('StreamBufferCountMode', 'Manual');
                end
                if sn.has('StreamBufferCountManual') && sn.isWritable('StreamBufferCountManual')
                    sn.setIfDifferent('StreamBufferCountManual', 100);
                end
            catch me
                warning('spincam:stream:buffers', 'Could not configure host buffers for %s: %s', ...
                    obj.Serial, me.message);
            end
        end
    end

    methods (Static)
        function plan = defaultPlan()
            plan = struct('Mode', 'passive', 'TtlLine', 0, 'TtlSource', 'none', ...
                'FrameCounterOffset', -1, 'GpioOffset', -1, 'Gate', 'none');
        end
    end

    methods (Static, Access = private)
        function value = coerce(info, value, label)
            switch info.Type
                case {'float', 'integer'}
                    if ~(isnumeric(value) || islogical(value)) || ~isscalar(value)
                        error('spincam:property:badValue', '%s expects a numeric scalar.', label);
                    end
                    value = double(value);
                    if ~isempty(info.Min) && value < info.Min
                        warning('spincam:property:clamped', '%s = %g is below the minimum; using %g.', ...
                            label, value, info.Min);
                        value = info.Min;
                    elseif ~isempty(info.Max) && value > info.Max
                        warning('spincam:property:clamped', '%s = %g is above the maximum; using %g.', ...
                            label, value, info.Max);
                        value = info.Max;
                    end
                    if strcmp(info.Type, 'integer')
                        inc = 1;
                        if ~isempty(info.Increment) && info.Increment > 0
                            inc = info.Increment;
                        end
                        base = 0;
                        if ~isempty(info.Min)
                            base = info.Min;
                        end
                        value = base + round((value - base) / inc) * inc;
                        if ~isempty(info.Max) && value > info.Max
                            value = value - inc;
                        end
                    end
                case 'bool'
                    value = logical(value);
                case 'enum'
                    value = char(value);
                    match = info.Entries(strcmpi(info.Entries, value));
                    if isempty(match)
                        error('spincam:property:badValue', '%s must be one of: %s.', label, ...
                            strjoin(info.Entries, ', '));
                    end
                    value = match{1};
                case 'string'
                    value = char(value);
            end
        end

        function e = netTtlSource(name)
            switch name
                case 'embedded'
                    e = SpinCam.TtlSource.Embedded;
                case 'polled'
                    e = SpinCam.TtlSource.Polled;
                otherwise
                    e = SpinCam.TtlSource.None;
            end
        end
    end
end

function v = alignDown(value, info, upper)
%ALIGNDOWN Clamp VALUE to [Min, min(Max, UPPER)] and round down to Min + k*Increment.
lo = 0;
if ~isempty(info.Min)
    lo = info.Min;
end
hi = upper;
if ~isempty(info.Max)
    hi = min(hi, info.Max);
end
inc = 1;
if ~isempty(info.Increment) && info.Increment > 0
    inc = info.Increment;
end
v = min(max(value, lo), hi);
v = lo + floor((v - lo) / inc) * inc;
end

function v = readOr(nm, name, default)
v = default;
try
    if nm.has(name) && nm.isReadable(name)
        v = nm.get(name);
    end
catch
end
end
