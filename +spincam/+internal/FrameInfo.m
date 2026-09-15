classdef FrameInfo
    %FRAMEINFO Bit maths for the IIDC FRAME_INFO register (0x12F8).
    %   FRAME_INFO controls image-specific data the camera embeds into the first
    %   bytes of every image. IIDC numbers register bits MSB-first: bit n has the
    %   value 2^(31-n). Inquiry bits 6..15 report support; enable bits 22..31 turn
    %   fields on. Enabled fields are packed from byte 0 in descending enable-bit
    %   order, 4 bytes each, big-endian. The GPIO word stores Line k at bit (31-k).
    %   Layout verified on CM3-U3-13Y3M FW 1.13.3.00 (see CLAUDE.md section 3).

    properties (Constant)
        RegisterOffset = uint32(hex2dec('12F8'))
        % Packing order (first field occupies bytes 0-3).
        Fields = {'Timestamp', 'Gain', 'Shutter', 'Brightness', 'Exposure', ...
            'WhiteBalance', 'FrameCounter', 'StrobePattern', 'GPIO', 'ROI'}
        EnableBits = [31 30 29 28 27 26 25 24 23 22]
    end

    methods (Static)
        function m = bitMask(bit)
            %BITMASK Value of IIDC (MSB-first) bit number BIT.
            m = bitshift(uint32(1), 31 - bit);
        end

        function tf = isPresent(regValue)
            tf = bitand(uint32(regValue), spincam.internal.FrameInfo.bitMask(0)) ~= 0;
        end

        function bit = enableBit(field)
            idx = find(strcmpi(spincam.internal.FrameInfo.Fields, field), 1);
            if isempty(idx)
                error('spincam:frameinfo:unknownField', ...
                    'Unknown FRAME_INFO field "%s". Valid: %s.', field, ...
                    strjoin(spincam.internal.FrameInfo.Fields, ', '));
            end
            bit = spincam.internal.FrameInfo.EnableBits(idx);
        end

        function tf = isSupported(regValue, field)
            %ISSUPPORTED True when the inquiry bit for FIELD is set.
            F = spincam.internal.FrameInfo;
            inquiryBit = F.enableBit(field) - 16;
            tf = F.isPresent(regValue) && bitand(uint32(regValue), F.bitMask(inquiryBit)) ~= 0;
        end

        function v = configure(regValue, fields)
            %CONFIGURE Returns REGVALUE with exactly FIELDS enabled (others off).
            arguments
                regValue
                fields cell = {}
            end
            F = spincam.internal.FrameInfo;
            v = bitand(uint32(regValue), bitcmp(uint32(hex2dec('3FF'))));
            for k = 1:numel(fields)
                v = bitor(v, F.bitMask(F.enableBit(fields{k})));
            end
        end

        function fields = enabledFields(regValue)
            %ENABLEDFIELDS Enabled field names in packing order.
            F = spincam.internal.FrameInfo;
            on = arrayfun(@(b) bitand(uint32(regValue), F.bitMask(b)) ~= 0, F.EnableBits);
            fields = F.Fields(on);
        end

        function offset = byteOffset(regValue, field)
            %BYTEOFFSET Byte offset of FIELD in the image, or -1 when not enabled.
            fields = spincam.internal.FrameInfo.enabledFields(regValue);
            idx = find(strcmpi(fields, field), 1);
            if isempty(idx)
                offset = -1;
            else
                offset = 4 * (idx - 1);
            end
        end

        function lines = decodeGpio(raw)
            %DECODEGPIO Embedded GPIO word -> bitfield with bit k = Line k.
            raw = uint32(raw);
            lines = 0;
            for k = 0:3
                if bitand(raw, bitshift(uint32(1), 31 - k)) ~= 0
                    lines = lines + 2^k;
                end
            end
        end

        function raw = encodeGpio(lines)
            raw = uint32(0);
            for k = 0:3
                if bitand(uint32(lines), bitshift(uint32(1), k)) ~= 0
                    raw = bitor(raw, bitshift(uint32(1), 31 - k));
                end
            end
        end

        function v = readBigEndian32(bytes, offset)
            %READBIGENDIAN32 uint32 from BYTES(offset+1:offset+4), big-endian.
            b = double(bytes(offset + 1:offset + 4));
            v = uint32(b(1) * 2^24 + b(2) * 2^16 + b(3) * 2^8 + b(4));
        end
    end
end
