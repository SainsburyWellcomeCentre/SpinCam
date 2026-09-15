classdef (Abstract) RegisterPort < handle
    %REGISTERPORT Access to IIDC camera registers by offset (real or mock).
    %   Offsets are relative to the IIDC register base (e.g. 0x12F8 FRAME_INFO).
    %   Values are uint32 in the register's logical bit order.

    methods (Abstract)
        v = read(obj, offset)
        write(obj, offset, value)
    end

    methods
        function v = update(obj, offset, fcn)
            %UPDATE Read-modify-write; returns the value read back.
            current = obj.read(offset);
            obj.write(offset, fcn(current));
            v = obj.read(offset);
        end
    end
end
