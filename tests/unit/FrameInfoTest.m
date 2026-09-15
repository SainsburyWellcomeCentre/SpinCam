classdef FrameInfoTest < matlab.unittest.TestCase
    %FRAMEINFOTEST FRAME_INFO register maths against values read from real cameras.

    properties (Constant)
        Default = uint32(hex2dec('87FF0000'))
    end

    methods (Test)
        function defaultRegisterReportsSupport(tc)
            F = spincam.internal.FrameInfo;
            tc.verifyTrue(F.isPresent(tc.Default));
            tc.verifyTrue(F.isSupported(tc.Default, 'GPIO'));
            tc.verifyTrue(F.isSupported(tc.Default, 'FrameCounter'));
            tc.verifyEmpty(F.enabledFields(tc.Default));
        end

        function configureMatchesVerifiedHardwareWrite(tc)
            F = spincam.internal.FrameInfo;
            v = F.configure(tc.Default, {'GPIO', 'FrameCounter'});
            tc.verifyEqual(v, uint32(hex2dec('87FF0140')));
        end

        function byteOffsetsFollowPackingOrder(tc)
            F = spincam.internal.FrameInfo;
            v = uint32(hex2dec('87FF0140'));
            tc.verifyEqual(F.byteOffset(v, 'FrameCounter'), 0);
            tc.verifyEqual(F.byteOffset(v, 'GPIO'), 4);
            tc.verifyEqual(F.byteOffset(v, 'Timestamp'), -1);
            everything = F.configure(tc.Default, F.Fields);
            tc.verifyEqual(F.byteOffset(everything, 'Timestamp'), 0);
            tc.verifyEqual(F.byteOffset(everything, 'Gain'), 4);
            tc.verifyEqual(F.byteOffset(everything, 'FrameCounter'), 24);
            tc.verifyEqual(F.byteOffset(everything, 'ROI'), 36);
        end

        function gpioOnlyStartsAtByteZero(tc)
            F = spincam.internal.FrameInfo;
            v = F.configure(tc.Default, {'GPIO'});
            tc.verifyEqual(F.byteOffset(v, 'GPIO'), 0);
        end

        function configureClearsOtherFieldsAndKeepsInquiryBits(tc)
            F = spincam.internal.FrameInfo;
            v = F.configure(F.configure(tc.Default, {'Timestamp', 'Gain'}), {'GPIO'});
            tc.verifyEqual(F.enabledFields(v), {'GPIO'});
            tc.verifyEqual(bitand(v, bitcmp(uint32(hex2dec('3FF')))), tc.Default);
        end

        function unsupportedWhenInquiryBitClear(tc)
            F = spincam.internal.FrameInfo;
            v = bitand(tc.Default, bitcmp(F.bitMask(7)));
            tc.verifyFalse(F.isSupported(v, 'GPIO'));
            tc.verifyTrue(F.isSupported(v, 'FrameCounter'));
        end

        function gpioDecodingMatchesObservedCameras(tc)
            F = spincam.internal.FrameInfo;
            tc.verifyEqual(F.decodeGpio(hex2dec('10000000')), 8);    % camera 1: Line3 high
            tc.verifyEqual(F.decodeGpio(hex2dec('30000000')), 12);   % camera 2: Line2+Line3 high
            tc.verifyEqual(F.decodeGpio(hex2dec('80000000')), 1);    % Line0
        end

        function gpioRoundTrip(tc)
            F = spincam.internal.FrameInfo;
            for lines = 0:15
                tc.verifyEqual(F.decodeGpio(F.encodeGpio(lines)), lines);
            end
        end

        function readsBytesCapturedFromCamera(tc)
            F = spincam.internal.FrameInfo;
            bytes = uint8([0 17 138 187 16 0 0 0 10 13 10 12]);   % FrameID 0 of camera 24226887
            tc.verifyEqual(F.readBigEndian32(bytes, 0), uint32(1149627));
            tc.verifyEqual(F.decodeGpio(F.readBigEndian32(bytes, 4)), 8);
        end

        function unknownFieldErrors(tc)
            tc.verifyError(@() spincam.internal.FrameInfo.enableBit('Nope'), 'spincam:frameinfo:unknownField');
        end
    end
end
