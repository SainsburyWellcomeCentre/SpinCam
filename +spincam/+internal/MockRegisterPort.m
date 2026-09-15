classdef MockRegisterPort < spincam.internal.RegisterPort
    %MOCKREGISTERPORT In-memory IIDC registers with the CM3 values read on 2026-09-15.
    %   Read-only bits (inquiry/presence fields) are preserved on write for the
    %   registers spincam uses. Unknown offsets raise the same error class as a
    %   bad address on the real camera. Writes are logged as {offset, value}.

    properties (SetAccess = private)
        WriteLog = cell(0, 2)
    end

    properties (Access = private)
        Values
        WritableMasks
    end

    methods
        function obj = MockRegisterPort(serial)
            arguments
                serial (1,:) char = '24226887'
            end
            obj.Values = containers.Map('KeyType', 'double', 'ValueType', 'any');
            obj.WritableMasks = containers.Map('KeyType', 'double', 'ValueType', 'any');
            h = @hex2dec;
            obj.define(h('1100'), h('80040008'), 0);            % GPIO_CTRL (read-only)
            obj.define(h('1104'), h('4000003C'), h('FFFFFFFF'));
            obj.define(h('110C'), h('80000100'), h('00001F00')); % STRPAT_CTRL: Count_Period
            obj.define(h('1110'), h('80000000'), h('7FFFFFFF'));
            obj.define(h('1120'), h('80080003'), h('7FFFFFFF'));
            obj.define(h('1130'), h('80000000'), h('7FFFFFFF'));
            obj.define(h('1140'), h('80000001'), h('7FFFFFFF'));
            for k = 0:3
                obj.define(h('1118') + 16 * k, h('8000FFFF'), h('0000FFFF'));  % STRPAT_MASK_PIN_k
                obj.define(h('1114') + 16 * k, 0, h('FFFFFFFF'));
            end
            obj.define(h('12F8'), h('87FF0000'), h('000003FF'));  % FRAME_INFO: enable bits only
            obj.define(h('1F20'), str2double(serial), 0);        % SERIAL_NUMBER
        end

        function v = read(obj, offset)
            key = double(offset);
            if ~isKey(obj.Values, key)
                error('spincam:register:readFailed', ...
                    'Reading register 0x%04X failed: Could not read remote Port on device [-1008]', key);
            end
            v = uint32(obj.Values(key));
        end

        function write(obj, offset, value)
            key = double(offset);
            if ~isKey(obj.Values, key)
                error('spincam:register:writeFailed', ...
                    'Writing register 0x%04X failed: Could not write remote Port on device [-1008]', key);
            end
            mask = uint32(obj.WritableMasks(key));
            old = uint32(obj.Values(key));
            obj.Values(key) = bitor(bitand(old, bitcmp(mask)), bitand(uint32(value), mask));
            obj.WriteLog(end + 1, :) = {key, uint32(value)};
        end

        function clearLog(obj)
            obj.WriteLog = cell(0, 2);
        end

        function setRaw(obj, offset, value)
            %SETRAW Overwrite a register ignoring masks (e.g. simulate unsupported features).
            obj.Values(double(offset)) = uint32(value);
        end
    end

    methods (Access = private)
        function define(obj, offset, value, writableMask)
            obj.Values(double(offset)) = uint32(value);
            obj.WritableMasks(double(offset)) = uint32(writableMask);
        end
    end
end
