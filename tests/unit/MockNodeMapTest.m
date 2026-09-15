classdef MockNodeMapTest < matlab.unittest.TestCase
    %MOCKNODEMAPTEST The mock must enforce the CM3 access rules other tests rely on.

    properties
        NM
    end

    methods (TestMethodSetup)
        function create(tc)
            tc.NM = spincam.internal.MockNodeMap.cm3();
        end
    end

    methods (Test)
        function frameRateGatedByAutoMode(tc)
            tc.verifyFalse(tc.NM.isWritable('AcquisitionFrameRate'));
            tc.NM.set('AcquisitionFrameRateAuto', 'Off');
            tc.verifyTrue(tc.NM.isWritable('AcquisitionFrameRate'));
        end

        function triggerSourceRequiresTriggerModeOff(tc)
            tc.NM.set('TriggerMode', 'On');
            tc.verifyError(@() tc.NM.set('TriggerSource', 'Line2'), 'spincam:node:notWritable');
            tc.NM.set('TriggerMode', 'Off');
            tc.NM.set('TriggerSource', 'Line2');
            tc.verifyEqual(tc.NM.get('TriggerSource'), 'Line2');
        end

        function lineCapabilitiesPerLine(tc)
            nm = tc.NM;
            nm.set('LineSelector', 'Line0');
            tc.verifyEqual(nm.info('LineMode').Entries, {'Input'});
            tc.verifyFalse(nm.isAvailable('LineSource'));
            nm.set('LineSelector', 'Line1');
            tc.verifyEqual(nm.get('LineMode'), 'Output');
            tc.verifyTrue(nm.isAvailable('LineSource'));
            tc.verifyTrue(any(strcmp(nm.info('LineSource').Entries, 'UserOutput1')));
            nm.set('LineSelector', 'Line2');
            tc.verifyFalse(nm.isAvailable('StrobeDuration'));
            nm.set('LineMode', 'Output');
            tc.verifyTrue(nm.isAvailable('StrobeDuration'));
        end

        function selectorScopesValues(tc)
            nm = tc.NM;
            nm.set('LineSelector', 'Line2');
            nm.set('LineMode', 'Output');
            nm.set('LineSelector', 'Line3');
            tc.verifyEqual(nm.get('LineMode'), 'Input');
            nm.set('LineSelector', 'Line2');
            tc.verifyEqual(nm.get('LineMode'), 'Output');
        end

        function rejectsOutOfRangeAndBadEntries(tc)
            nm = tc.NM;
            nm.set('ExposureAuto', 'Off');
            tc.verifyError(@() nm.set('ExposureTime', 1e9), 'spincam:node:writeFailed');
            tc.verifyError(@() nm.set('PixelFormat', 'RGB8'), 'spincam:node:writeFailed');
            nm.set('LineSelector', 'Line0');
            tc.verifyError(@() nm.set('LineMode', 'Output'), 'spincam:node:writeFailed');
        end

        function unavailableNodesAreNotReadable(tc)
            tc.verifyError(@() tc.NM.get('Gamma'), 'spincam:node:notReadable');
        end

        function imageFormatLocksWhileStreaming(tc)
            tc.NM.setRaw('TLParamsLocked', 1);
            tc.verifyFalse(tc.NM.isWritable('Width'));
        end

        function writeLogRecordsOrderAndContext(tc)
            nm = tc.NM;
            nm.set('LineSelector', 'Line1');
            nm.set('StrobeDuration', 500);
            tc.verifyEqual(nm.writtenNames(), {'LineSelector', 'StrobeDuration'});
            tc.verifyEqual(nm.WriteLog{2, 3}, 'LineSelector=Line1');
        end
    end
end
