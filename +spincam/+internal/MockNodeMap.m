classdef MockNodeMap < spincam.internal.NodeMapAdapter
    %MOCKNODEMAP In-memory GenICam node map with Chameleon3-like access rules.
    %   Behaviour mirrors what was measured on CM3-U3-13Y3M FW 1.13.3.00
    %   (CLAUDE.md section 3): auto modes gate writability, LineSelector scopes
    %   line nodes, line capabilities differ per line, TriggerSource is writable
    %   only while TriggerMode is Off, image-format nodes lock while streaming,
    %   and GenICam-style errors are raised for range/entry violations.
    %
    %   Every successful write is appended to WriteLog as {name, value, context}
    %   so tests can assert write ordering.
    %
    %   nm = spincam.internal.MockNodeMap.cm3()         camera node map
    %   nm = spincam.internal.MockNodeMap.cm3Stream()   TL stream node map

    properties (SetAccess = private)
        WriteLog = cell(0, 3)
    end

    properties (Access = private)
        Nodes
        Overrides
        Rules
    end

    methods
        function obj = MockNodeMap()
            obj.Nodes = containers.Map('KeyType', 'char', 'ValueType', 'any');
            obj.Overrides = containers.Map('KeyType', 'char', 'ValueType', 'any');
            obj.Rules = containers.Map('KeyType', 'char', 'ValueType', 'any');
        end

        function addNode(obj, name, type, value, opts)
            arguments
                obj
                name (1,:) char
                type (1,:) char {mustBeMember(type, {'float', 'integer', 'bool', 'enum', 'string', 'command'})}
                value = []
                opts.Min (1,1) double = -Inf
                opts.Max (1,1) double = Inf
                opts.Increment (1,1) double = 1
                opts.Unit (1,:) char = ''
                opts.Entries cell = {}
                opts.Writable (1,1) logical = true
                opts.Available (1,1) logical = true
                opts.SelectedBy (1,:) char = ''
            end
            nd = struct('Type', type, 'Min', opts.Min, 'Max', opts.Max, ...
                'Increment', opts.Increment, 'Unit', opts.Unit, 'Entries', {opts.Entries}, ...
                'Writable', opts.Writable, 'Available', opts.Available, ...
                'SelectedBy', opts.SelectedBy, 'Default', {value}, ...
                'Values', containers.Map('KeyType', 'char', 'ValueType', 'any'));
            obj.Nodes(name) = nd;
        end

        function setValueFor(obj, name, selectorValue, value)
            %SETVALUEFOR Initial value of a selector-scoped node for one selector value.
            nd = obj.nodeStruct(name);
            nd.Values(selectorValue) = value;
        end

        function setOverride(obj, name, selectorValue, overrides)
            %SETOVERRIDE Per-selector attribute overrides (Entries, Min, Max, Available...).
            obj.Overrides([name '@' selectorValue]) = overrides;
        end

        function setRule(obj, name, fcn)
            %SETRULE Dynamic attributes: fcn(mockNodeMap) returns a struct of overrides.
            %   Rules must read other nodes with rawValue (not get) to avoid recursion.
            obj.Rules(name) = fcn;
        end

        function setRaw(obj, name, value)
            %SETRAW Changes a value without access checks or logging (simulates the camera).
            nd = obj.nodeStruct(name);
            nd.Values(obj.selectorKey(nd)) = value;
        end

        function v = rawValue(obj, name)
            nd = obj.nodeStruct(name);
            key = obj.selectorKey(nd);
            if isKey(nd.Values, key)
                v = nd.Values(key);
            else
                v = nd.Default;
            end
        end

        function clearLog(obj)
            obj.WriteLog = cell(0, 3);
        end

        function names = writtenNames(obj)
            names = obj.WriteLog(:, 1)';
        end

        function tf = has(obj, name)
            tf = isKey(obj.Nodes, char(name));
        end

        function s = info(obj, name)
            nd = obj.nodeStruct(name);
            e = obj.effective(name);
            s = struct('Name', char(name), 'Type', nd.Type, 'Available', e.Available, ...
                'Readable', e.Readable, 'Writable', e.Writable, 'Value', [], 'Min', [], ...
                'Max', [], 'Increment', [], 'Unit', nd.Unit, 'Entries', {{}});
            if ~e.Readable
                return
            end
            s.Value = obj.rawValue(name);
            switch nd.Type
                case 'float'
                    s.Min = e.Min;
                    s.Max = e.Max;
                case 'integer'
                    s.Min = e.Min;
                    s.Max = e.Max;
                    s.Increment = e.Increment;
                case 'enum'
                    s.Entries = e.Entries;
            end
        end

        function v = get(obj, name)
            e = obj.effective(name);
            if ~e.Readable
                error('spincam:node:notReadable', 'Node %s is not readable (available=%d).', ...
                    name, e.Available);
            end
            v = obj.rawValue(name);
        end

        function set(obj, name, value)
            nd = obj.nodeStruct(name);
            e = obj.effective(name);
            if ~e.Writable
                error('spincam:node:notWritable', 'Node %s is not writable (available=%d).', ...
                    name, e.Available);
            end
            switch nd.Type
                case {'float', 'integer'}
                    value = double(value);
                    if ~isscalar(value) || ~isfinite(value)
                        error('spincam:node:writeFailed', 'Writing %s failed: value must be a finite scalar.', name);
                    end
                    if value < e.Min || value > e.Max
                        error('spincam:node:writeFailed', ...
                            'Writing %s = %g failed: OutOfRangeException, allowed [%g, %g].', ...
                            name, value, e.Min, e.Max);
                    end
                    if strcmp(nd.Type, 'integer') && abs(mod(value - e.Min, e.Increment)) > 0
                        error('spincam:node:writeFailed', ...
                            'Writing %s = %g failed: value must be Min + k*%g.', name, value, e.Increment);
                    end
                case 'bool'
                    value = logical(value);
                case 'enum'
                    value = char(value);
                    if ~any(strcmp(e.Entries, value))
                        error('spincam:node:writeFailed', ...
                            'Writing %s = %s failed: entry not available (%s).', ...
                            name, value, strjoin(e.Entries, '|'));
                    end
                case 'string'
                    value = char(value);
                otherwise
                    error('spincam:node:unsupportedType', 'Cannot write %s node %s.', nd.Type, name);
            end
            nd.Values(obj.selectorKey(nd)) = value;
            obj.WriteLog(end + 1, :) = {char(name), value, obj.contextString(nd)};
        end

        function execute(obj, name)
            nd = obj.nodeStruct(name);
            e = obj.effective(name);
            if ~strcmp(nd.Type, 'command') || ~e.Available
                error('spincam:node:executeFailed', 'Node %s cannot be executed.', name);
            end
            obj.WriteLog(end + 1, :) = {char(name), 'execute', obj.contextString(nd)};
        end
    end

    methods (Access = private)
        function nd = nodeStruct(obj, name)
            name = char(name);
            if ~isKey(obj.Nodes, name)
                error('spincam:node:missing', 'Node %s does not exist.', name);
            end
            nd = obj.Nodes(name);
        end

        function key = selectorKey(obj, nd)
            if isempty(nd.SelectedBy)
                key = '*';
            else
                key = char(obj.rawValue(nd.SelectedBy));
            end
        end

        function ctx = contextString(obj, nd)
            if isempty(nd.SelectedBy)
                ctx = '';
            else
                ctx = sprintf('%s=%s', nd.SelectedBy, obj.selectorKey(nd));
            end
        end

        function e = effective(obj, name)
            nd = obj.nodeStruct(name);
            key = obj.selectorKey(nd);
            e = struct('Available', nd.Available, 'Readable', ~strcmp(nd.Type, 'command'), ...
                'Writable', nd.Writable, 'Entries', {nd.Entries}, 'Min', nd.Min, ...
                'Max', nd.Max, 'Increment', nd.Increment);
            overrideKey = [char(name) '@' key];
            if isKey(obj.Overrides, overrideKey)
                e = mergeStruct(e, obj.Overrides(overrideKey));
            end
            if isKey(obj.Rules, char(name))
                rule = obj.Rules(char(name));
                e = mergeStruct(e, rule(obj));
            end
            if ~e.Available
                e.Readable = false;
                e.Writable = false;
            end
        end
    end

    methods (Static)
        function nm = cm3(opts)
            %CM3 Node map modelled on Chameleon3 CM3-U3-13Y3M (FW 1.13.3.00).
            arguments
                opts.Serial (1,:) char = '24226887'
                opts.GammaAvailable (1,1) logical = false
                opts.Width (1,1) double = 1280
                opts.Height (1,1) double = 1024
            end
            nm = spincam.internal.MockNodeMap();
            ro = {'Writable', false};

            nm.addNode('DeviceSerialNumber', 'string', opts.Serial, ro{:});
            nm.addNode('DeviceModelName', 'string', 'Chameleon3 CM3-U3-13Y3M (mock)', ro{:});
            nm.addNode('DeviceVendorName', 'string', 'Point Grey Research', ro{:});
            nm.addNode('DeviceFirmwareVersion', 'string', '1.13.3.00', ro{:});
            nm.addNode('DeviceVersion', 'string', 'FW:v1.13.3.00 FPGA:v2.02', ro{:});
            nm.addNode('DeviceCurrentSpeed', 'enum', 'SuperSpeed', 'Entries', {'SuperSpeed'}, ro{:});
            nm.addNode('DeviceTemperature', 'float', 47.05, 'Unit', 'C', ro{:});
            nm.addNode('DeviceLinkThroughputLimit', 'integer', 198112000, 'Min', 1312000, 'Max', 198112000);
            nm.addNode('DeviceMaxThroughput', 'integer', 198112000, ro{:});
            nm.addNode('TLParamsLocked', 'integer', 0, 'Min', 0, 'Max', 1);

            nm.addNode('AcquisitionMode', 'enum', 'Continuous', 'Entries', {'Continuous', 'SingleFrame', 'MultiFrame'});
            nm.addNode('AcquisitionFrameRateAuto', 'enum', 'Continuous', 'Entries', {'Off', 'Continuous'});
            nm.addNode('AcquisitionFrameRateEnabled', 'bool', true);
            nm.addNode('AcquisitionFrameRate', 'float', 150.714, 'Min', 1, 'Max', 150.716, 'Unit', 'Hz');
            nm.setRule('AcquisitionFrameRate', @(m) struct( ...
                'Writable', strcmp(m.rawValue('AcquisitionFrameRateAuto'), 'Off') && m.rawValue('AcquisitionFrameRateEnabled'), ...
                'Max', spincam.internal.MockNodeMap.cm3MaxFrameRate(m)));

            nm.addNode('ExposureAuto', 'enum', 'Continuous', 'Entries', {'Off', 'Once', 'Continuous'});
            nm.addNode('ExposureMode', 'enum', 'Timed', 'Entries', {'Timed', 'TriggerWidth'});
            nm.addNode('ExposureTime', 'float', 6573.56, 'Min', 6.3777, 'Max', 6573.56, 'Unit', 'us');
            nm.setRule('ExposureTime', @(m) struct( ...
                'Writable', strcmp(m.rawValue('ExposureAuto'), 'Off'), ...
                'Max', spincam.internal.MockNodeMap.cm3MaxExposure(m)));
            nm.addNode('pgrExposureCompensationAuto', 'enum', 'Continuous', 'Entries', {'Off', 'Once', 'Continuous'});

            nm.addNode('GainAuto', 'enum', 'Continuous', 'Entries', {'Off', 'Once', 'Continuous'});
            nm.addNode('Gain', 'float', 18.0622, 'Min', 0, 'Max', 24, 'Unit', 'dB');
            nm.setRule('Gain', @(m) struct('Writable', strcmp(m.rawValue('GainAuto'), 'Off')));
            nm.addNode('BlackLevel', 'float', 1.95312, 'Min', 0, 'Max', 24.9023, 'Unit', '%');
            nm.addNode('Gamma', 'float', 1, 'Min', 0.5, 'Max', 4, 'Available', opts.GammaAvailable);
            nm.addNode('GammaEnabled', 'bool', false, 'Available', opts.GammaAvailable);
            nm.addNode('Sharpness', 'integer', 1024, 'Min', 0, 'Max', 4095, ro{:});
            nm.addNode('SharpnessEnabled', 'bool', false, 'Available', false);

            unlocked = @(m) struct('Writable', m.rawValue('TLParamsLocked') == 0);
            nm.addNode('PixelFormat', 'enum', 'Mono8', 'Entries', {'Mono8', 'Mono12Packed', 'Mono12p', 'Mono16'});
            nm.setRule('PixelFormat', unlocked);
            % ROI as read from the CM3: increments Width 16, Height 2, OffsetX 8, OffsetY 2; sensor-size
            % nodes present; Width/Height maxima shrink by the current offset.
            nm.addNode('SensorWidth', 'integer', opts.Width, 'Min', 0, 'Max', 65535, ro{:});
            nm.addNode('SensorHeight', 'integer', opts.Height, 'Min', 0, 'Max', 65535, ro{:});
            nm.addNode('WidthMax', 'integer', opts.Width, 'Min', 0, 'Max', 65535, ro{:});
            nm.addNode('HeightMax', 'integer', opts.Height, 'Min', 0, 'Max', 65535, ro{:});
            nm.addNode('Width', 'integer', opts.Width, 'Min', 16, 'Max', opts.Width, 'Increment', 16);
            nm.setRule('Width', @(m) struct('Writable', m.rawValue('TLParamsLocked') == 0, ...
                'Max', opts.Width - m.rawValue('OffsetX')));
            nm.addNode('Height', 'integer', opts.Height, 'Min', 2, 'Max', opts.Height, 'Increment', 2);
            nm.setRule('Height', @(m) struct('Writable', m.rawValue('TLParamsLocked') == 0, ...
                'Max', opts.Height - m.rawValue('OffsetY')));
            nm.addNode('OffsetX', 'integer', 0, 'Min', 0, 'Max', 0, 'Increment', 8);
            nm.setRule('OffsetX', @(m) struct('Writable', m.rawValue('TLParamsLocked') == 0, ...
                'Max', opts.Width - m.rawValue('Width')));
            nm.addNode('OffsetY', 'integer', 0, 'Min', 0, 'Max', 0, 'Increment', 2);
            nm.setRule('OffsetY', @(m) struct('Writable', m.rawValue('TLParamsLocked') == 0, ...
                'Max', opts.Height - m.rawValue('Height')));

            nm.addNode('TriggerSelector', 'enum', 'FrameStart', 'Entries', {'FrameStart', 'ExposureActive'});
            nm.addNode('TriggerMode', 'enum', 'Off', 'Entries', {'Off', 'On'});
            nm.addNode('TriggerSource', 'enum', 'Line0', 'Entries', {'Software', 'Line0', 'Line2', 'Line3'});
            nm.setRule('TriggerSource', @(m) struct('Writable', strcmp(m.rawValue('TriggerMode'), 'Off')));
            nm.addNode('TriggerActivation', 'enum', 'FallingEdge', 'Entries', {'RisingEdge', 'FallingEdge'});
            nm.addNode('TriggerOverlap', 'enum', 'Off', 'Entries', {'Off', 'ReadOut'});
            nm.setRule('TriggerOverlap', @(m) struct('Available', strcmp(m.rawValue('TriggerMode'), 'On')));
            nm.addNode('TriggerDelayEnabled', 'bool', false);
            nm.addNode('TriggerDelay', 'float', 0, 'Min', 0, 'Max', 6635.07, 'Unit', 'us');
            nm.addNode('TriggerSoftware', 'command');

            nm.addNode('LineSelector', 'enum', 'Line0', 'Entries', {'Line0', 'Line1', 'Line2', 'Line3'});
            nm.addNode('LineMode', 'enum', 'Input', 'Entries', {'Input', 'Output'}, 'SelectedBy', 'LineSelector');
            nm.setValueFor('LineMode', 'Line1', 'Output');
            nm.setOverride('LineMode', 'Line0', struct('Entries', {{'Input'}}));
            nm.setOverride('LineMode', 'Line1', struct('Entries', {{'Output'}}));
            outputOnly = @(m) struct('Available', strcmp(m.rawValue('LineMode'), 'Output'));
            nm.addNode('LineSource', 'enum', 'ExposureActive', 'SelectedBy', 'LineSelector', ...
                'Entries', {'ExposureActive', 'ExternalTriggerActive'});
            for k = 1:3
                nm.setOverride('LineSource', sprintf('Line%d', k), struct('Entries', ...
                    {{'ExposureActive', 'ExternalTriggerActive', sprintf('UserOutput%d', k)}}));
            end
            nm.setRule('LineSource', outputOnly);
            nm.addNode('LineInverter', 'bool', false, 'SelectedBy', 'LineSelector');
            nm.setRule('LineInverter', outputOnly);
            nm.addNode('StrobeDuration', 'float', 0, 'Min', 0, 'Max', 65535, 'Unit', 'us', 'SelectedBy', 'LineSelector');
            nm.setRule('StrobeDuration', outputOnly);
            nm.addNode('StrobeDelay', 'float', 0, 'Min', 0, 'Max', 65535, 'Unit', 'us', 'SelectedBy', 'LineSelector');
            nm.setRule('StrobeDelay', outputOnly);
            nm.addNode('LineStatus', 'bool', false, 'SelectedBy', 'LineSelector', ro{:});
            nm.setValueFor('LineStatus', 'Line3', true);
            nm.addNode('LineStatusAll', 'integer', 8, 'Min', 0, 'Max', 15, ro{:});

            nm.addNode('ChunkModeActive', 'bool', false);
            nm.clearLog();
        end

        function nm = cm3Stream()
            %CM3STREAM Transport-layer stream node map.
            nm = spincam.internal.MockNodeMap();
            nm.addNode('StreamBufferHandlingMode', 'enum', 'OldestFirst', 'Entries', ...
                {'OldestFirst', 'OldestFirstOverwrite', 'NewestOnly', 'NewestFirst'});
            nm.addNode('StreamBufferCountMode', 'enum', 'Manual', 'Entries', {'Manual'});
            nm.addNode('StreamBufferCountManual', 'integer', 10, 'Min', 1, 'Max', 32523);
            nm.addNode('StreamDroppedFrameCount', 'integer', 0, 'Writable', false);
            nm.addNode('StreamLostFrameCount', 'integer', 0, 'Writable', false);
            nm.clearLog();
        end

        function fps = cm3MaxFrameRate(m)
            fps = 150.716;
            if strcmp(m.rawValue('ExposureAuto'), 'Off') && strcmp(m.rawValue('TriggerMode'), 'Off')
                fps = min(fps, 0.9908e6 / m.rawValue('ExposureTime'));
            end
        end

        function us = cm3MaxExposure(m)
            if strcmp(m.rawValue('TriggerMode'), 'On')
                us = 1e6;
            else
                us = floor(0.9908e6 / m.rawValue('AcquisitionFrameRate') * 100) / 100;
            end
        end
    end
end

function s = mergeStruct(s, overrides)
names = fieldnames(overrides);
for k = 1:numel(names)
    s.(names{k}) = overrides.(names{k});
end
end
