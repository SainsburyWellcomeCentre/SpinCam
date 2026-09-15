classdef (Abstract) NodeMapAdapter < handle
    %NODEMAPADAPTER Uniform access to a GenICam node map (real or mock).
    %   Values are MATLAB-native: double for float/integer, logical for bool,
    %   char for enum (symbolic) and string nodes.
    %
    %   info(name) returns a struct with fields
    %     Name, Type ('float'|'integer'|'bool'|'enum'|'string'|'command'|...),
    %     Available, Readable, Writable, Value, Min, Max, Increment, Unit, Entries

    methods (Abstract)
        tf = has(obj, name)
        s = info(obj, name)
        v = get(obj, name)
        set(obj, name, value)
        execute(obj, name)
    end

    methods
        function tf = isAvailable(obj, name)
            tf = obj.has(name) && obj.info(name).Available;
        end

        function tf = isReadable(obj, name)
            tf = obj.has(name) && obj.info(name).Readable;
        end

        function tf = isWritable(obj, name)
            tf = obj.has(name) && obj.info(name).Writable;
        end

        function name = firstExisting(obj, candidates)
            %FIRSTEXISTING First candidate node that exists ('' if none).
            name = '';
            for k = 1:numel(candidates)
                if obj.has(candidates{k})
                    name = candidates{k};
                    return
                end
            end
        end

        function setIfDifferent(obj, name, value)
            %SETIFDIFFERENT Writes only when the current value differs.
            %   Avoids needless writes (and AccessExceptions on read-only nodes
            %   that already hold the requested value).
            if obj.isReadable(name)
                current = obj.get(name);
                if isequal(current, value) || (ischar(value) && strcmp(current, value))
                    return
                end
            end
            obj.set(name, value);
        end
    end
end
