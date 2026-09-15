classdef SpinnakerRegisterPort < spincam.internal.RegisterPort
    %SPINNAKERREGISTERPORT IIDC register access through IManagedCamera.ReadPort/WritePort.
    %   Point Grey USB3 cameras map IIDC registers at 0xFFFFF0F00000 + offset, and
    %   the port returns register values little-endian (verified by reading the
    %   serial number register 0x1F20).

    properties (Constant)
        Base = uint64(hex2dec('FFFFF0F00000'))
    end

    properties (SetAccess = private)
        NetCamera
        Label char = ''
    end

    methods
        function obj = SpinnakerRegisterPort(netCamera, label)
            arguments
                netCamera
                label (1,:) char = ''
            end
            obj.NetCamera = netCamera;
            obj.Label = label;
        end

        function v = read(obj, offset)
            buffer = NET.createArray('System.Byte', 4);
            try
                obj.NetCamera.ReadPort(obj.Base + uint64(offset), buffer, uint64(4));
            catch me
                error('spincam:register:readFailed', '%sReading register 0x%04X failed: %s', ...
                    obj.prefix(), double(offset), strtok(me.message, newline));
            end
            v = typecast(uint8(buffer), 'uint32');
        end

        function write(obj, offset, value)
            buffer = NET.convertArray(typecast(uint32(value), 'uint8'), 'System.Byte');
            try
                obj.NetCamera.WritePort(obj.Base + uint64(offset), buffer, uint64(4));
            catch me
                error('spincam:register:writeFailed', '%sWriting register 0x%04X = 0x%08X failed: %s', ...
                    obj.prefix(), double(offset), double(value), strtok(me.message, newline));
            end
        end
    end

    methods (Access = private)
        function p = prefix(obj)
            if isempty(obj.Label)
                p = '';
            else
                p = ['[' obj.Label '] '];
            end
        end
    end
end
