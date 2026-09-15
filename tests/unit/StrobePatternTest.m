classdef StrobePatternTest < matlab.unittest.TestCase
    %STROBEPATTERNTEST GPIO strobe pattern register maths (values read from CM3 cameras).

    methods (Test)
        function readsDefaultPeriod(tc)
            P = spincam.internal.StrobePattern;
            tc.verifyTrue(P.isPresent(hex2dec('80000100')));
            tc.verifyEqual(P.period(hex2dec('80000100')), 1);
        end

        function setsPeriodPreservingOtherBits(tc)
            P = spincam.internal.StrobePattern;
            v = P.setPeriod(hex2dec('80000100'), 4);
            tc.verifyEqual(v, uint32(hex2dec('80000400')));
            tc.verifyEqual(P.period(v), 4);
            tc.verifyEqual(P.period(P.setPeriod(v, 16)), 16);
        end

        function maskSlots(tc)
            P = spincam.internal.StrobePattern;
            tc.verifyEqual(P.maskSlots(hex2dec('8000FFFF')), 0:15);
            tc.verifyEqual(P.setMaskSlots(hex2dec('8000FFFF'), 0), uint32(hex2dec('80008000')));
            % Register reference example: period 3, bit 18 set -> strobe when count == 2.
            tc.verifyEqual(P.setMaskSlots(hex2dec('8000FFFF'), 2), uint32(hex2dec('80002000')));
            tc.verifyEqual(P.maskSlots(hex2dec('80002000')), 2);
        end

        function maskOffsets(tc)
            P = spincam.internal.StrobePattern;
            tc.verifyEqual(P.maskOffset(0), uint32(hex2dec('1118')));
            tc.verifyEqual(P.maskOffset(3), uint32(hex2dec('1148')));
        end

        function rejectsOutOfRangePeriod(tc)
            P = spincam.internal.StrobePattern;
            tc.verifyError(@() P.setPeriod(0, 17), ?MException);
            tc.verifyError(@() P.setPeriod(0, 0), ?MException);
        end
    end
end
