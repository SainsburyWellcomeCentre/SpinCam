classdef StrobePattern
    %STROBEPATTERN Bit maths for the IIDC GPIO strobe pattern registers.
    %   GPIO_STRPAT_CTRL (0x110C): Count_Period in IIDC bits 19-23 (1..16),
    %   Current_Count in bits 28-31. GPIO_STRPAT_MASK_PIN_k (0x1118 + 0x10*k):
    %   Enable_Mask in bits 16-31, where IIDC bit 16+c enables a strobe when the
    %   shared counter equals c. A pin strobes on frame n when bit (n mod period)
    %   of its mask is set.

    properties (Constant)
        CtrlOffset = uint32(hex2dec('110C'))
        MaskOffsets = uint32([hex2dec('1118'), hex2dec('1128'), hex2dec('1138'), hex2dec('1148')])
        MaxPeriod = 16
    end

    methods (Static)
        function tf = isPresent(regValue)
            tf = bitand(uint32(regValue), uint32(hex2dec('80000000'))) ~= 0;
        end

        function n = period(ctrlValue)
            n = double(bitand(bitshift(uint32(ctrlValue), -8), uint32(31)));
        end

        function v = setPeriod(ctrlValue, n)
            arguments
                ctrlValue
                n (1,1) double {mustBeInteger, mustBeInRange(n, 1, 16)}
            end
            field = bitshift(uint32(31), 8);
            v = bitor(bitand(uint32(ctrlValue), bitcmp(field)), bitshift(uint32(n), 8));
        end

        function slots = maskSlots(maskValue)
            %MASKSLOTS Counter values (0-based) at which the pin strobes.
            slots = find(arrayfun(@(c) bitand(uint32(maskValue), bitshift(uint32(1), 15 - c)) ~= 0, 0:15)) - 1;
        end

        function v = setMaskSlots(maskValue, slots)
            arguments
                maskValue
                slots (1,:) double {mustBeInteger, mustBeInRange(slots, 0, 15)}
            end
            m = uint32(0);
            for c = slots
                m = bitor(m, bitshift(uint32(1), 15 - c));
            end
            v = bitor(bitand(uint32(maskValue), uint32(hex2dec('FFFF0000'))), m);
        end

        function offset = maskOffset(lineIndex)
            arguments
                lineIndex (1,1) double {mustBeInteger, mustBeInRange(lineIndex, 0, 3)}
            end
            offset = spincam.internal.StrobePattern.MaskOffsets(lineIndex + 1);
        end
    end
end
