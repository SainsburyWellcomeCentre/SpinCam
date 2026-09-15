classdef SpinnakerNodeMap < spincam.internal.NodeMapAdapter
    %SPINNAKERNODEMAP NodeMapAdapter over a SpinnakerNET.GenApi node map.
    %   Uses NET.invokeGenericMethod(GetNode<INode>) which returns concrete node
    %   classes (Float, Integer, BoolNode, Enumeration, StringReg, Command, ...).
    %   Enumeration nodes are written with FromString (assigning Value would need
    %   an EnumValue) and read with ToString.

    properties (SetAccess = private)
        NetNodeMap
        Label char = ''
    end

    properties (Access = private)
        Cache
    end

    methods
        function obj = SpinnakerNodeMap(netNodeMap, label)
            arguments
                netNodeMap
                label (1,:) char = ''
            end
            obj.NetNodeMap = netNodeMap;
            obj.Label = label;
            obj.Cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
        end

        function tf = has(obj, name)
            tf = ~isempty(obj.node(name));
        end

        function s = info(obj, name)
            nd = obj.requireNode(name);
            type = spincam.internal.SpinnakerNodeMap.typeOf(nd);
            s = struct('Name', char(name), 'Type', type, ...
                'Available', logical(nd.IsAvailable), 'Readable', logical(nd.IsReadable), ...
                'Writable', logical(nd.IsWritable), 'Value', [], 'Min', [], 'Max', [], ...
                'Increment', [], 'Unit', '', 'Entries', {{}});
            if ~s.Readable
                return
            end
            try
                s.Value = spincam.internal.SpinnakerNodeMap.readValue(nd, type);
                switch type
                    case 'float'
                        s.Min = double(nd.Min);
                        s.Max = double(nd.Max);
                        s.Unit = char(nd.Unit);
                    case 'integer'
                        s.Min = double(nd.Min);
                        s.Max = double(nd.Max);
                        s.Increment = double(nd.Increment);
                    case 'enum'
                        s.Entries = spincam.internal.SpinnakerNodeMap.availableEntries(nd);
                end
            catch me
                % Limits can become unreadable between checks (camera state changes).
                warning('spincam:node:infoPartial', 'Could not read all of %s: %s', name, ...
                    spincam.internal.SpinnakerNodeMap.firstLine(me.message));
            end
        end

        function v = get(obj, name)
            nd = obj.requireNode(name);
            if ~nd.IsReadable
                error('spincam:node:notReadable', '%sNode %s is not readable (available=%d).', ...
                    obj.prefix(), name, logical(nd.IsAvailable));
            end
            try
                v = spincam.internal.SpinnakerNodeMap.readValue(nd, ...
                    spincam.internal.SpinnakerNodeMap.typeOf(nd));
            catch me
                error('spincam:node:readFailed', '%sReading %s failed: %s', obj.prefix(), name, ...
                    spincam.internal.SpinnakerNodeMap.firstLine(me.message));
            end
        end

        function set(obj, name, value)
            nd = obj.requireNode(name);
            if ~nd.IsWritable
                error('spincam:node:notWritable', '%sNode %s is not writable (available=%d).', ...
                    obj.prefix(), name, logical(nd.IsAvailable));
            end
            type = spincam.internal.SpinnakerNodeMap.typeOf(nd);
            try
                switch type
                    case 'float'
                        nd.Value = double(value);
                    case 'integer'
                        nd.Value = int64(value);
                    case 'bool'
                        nd.Value = logical(value);
                    case 'enum'
                        nd.FromString(char(value));
                    case 'string'
                        nd.Value = char(value);
                    otherwise
                        error('spincam:node:unsupportedType', 'Cannot write %s node.', type);
                end
            catch me
                error('spincam:node:writeFailed', '%sWriting %s = %s failed: %s', obj.prefix(), ...
                    name, spincam.internal.SpinnakerNodeMap.valueText(value), ...
                    spincam.internal.SpinnakerNodeMap.firstLine(me.message));
            end
        end

        function execute(obj, name)
            nd = obj.requireNode(name);
            try
                nd.Execute();
            catch me
                error('spincam:node:executeFailed', '%sExecuting %s failed: %s', obj.prefix(), name, ...
                    spincam.internal.SpinnakerNodeMap.firstLine(me.message));
            end
        end
    end

    methods (Access = private)
        function nd = node(obj, name)
            name = char(name);
            if isKey(obj.Cache, name)
                nd = obj.Cache(name);
                return
            end
            try
                nd = NET.invokeGenericMethod(obj.NetNodeMap, 'GetNode', ...
                    {'SpinnakerNET.GenApi.INode'}, name);
            catch
                nd = [];
            end
            obj.Cache(name) = nd;
        end

        function nd = requireNode(obj, name)
            nd = obj.node(name);
            if isempty(nd)
                error('spincam:node:missing', '%sNode %s does not exist.', obj.prefix(), name);
            end
        end

        function p = prefix(obj)
            if isempty(obj.Label)
                p = '';
            else
                p = ['[' obj.Label '] '];
            end
        end
    end

    methods (Static, Access = private)
        function type = typeOf(nd)
            c = class(nd);
            if contains(c, 'Enum')
                type = 'enum';
            elseif contains(c, 'Float')
                type = 'float';
            elseif contains(c, 'Int')
                type = 'integer';
            elseif contains(c, 'Bool')
                type = 'bool';
            elseif contains(c, 'String')
                type = 'string';
            elseif contains(c, 'Command')
                type = 'command';
            elseif contains(c, 'Category')
                type = 'category';
            else
                type = 'unknown';
            end
        end

        function v = readValue(nd, type)
            switch type
                case {'float', 'integer'}
                    v = double(nd.Value);
                case 'bool'
                    v = logical(nd.Value);
                case 'enum'
                    v = char(nd.ToString());
                case 'string'
                    v = char(nd.Value);
                otherwise
                    v = [];
            end
        end

        function names = availableEntries(nd)
            entries = nd.Entries;
            names = {};
            for k = 1:entries.Length
                entry = entries(k);
                if entry.IsAvailable
                    names{end + 1} = char(entry.Symbolic); %#ok<AGROW>
                end
            end
        end

        function s = firstLine(msg)
            s = strtrim(strtok(msg, newline));
            s = regexprep(s, '^Message:\s*', '');
        end

        function t = valueText(v)
            if ischar(v) || isstring(v)
                t = char(v);
            else
                t = mat2str(v);
            end
        end
    end
end
