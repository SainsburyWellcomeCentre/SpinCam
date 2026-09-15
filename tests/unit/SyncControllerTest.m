classdef SyncControllerTest < matlab.unittest.TestCase
    %SYNCCONTROLLERTEST Node/register sequences and validation for sync modes A, B and C.

    properties
        NM
        Reg
        Device
    end

    properties (Constant)
        FrameInfo = double(hex2dec('12F8'))
        StrpatCtrl = double(hex2dec('110C'))
    end

    methods (TestMethodSetup)
        function create(tc)
            tc.NM = spincam.internal.MockNodeMap.cm3();
            tc.Reg = spincam.internal.MockRegisterPort('24226887');
            tc.Device = spincam.CameraDevice('24226887', tc.NM, spincam.internal.MockNodeMap.cm3Stream(), ...
                tc.Reg, [], true);
        end
    end

    methods (Test)
        function passiveEmbedsCounterAndGpio(tc)
            plan = spincam.SyncController('passive').apply(tc.Device);
            tc.verifyEqual(tc.Reg.read(tc.FrameInfo), uint32(hex2dec('87FF0140')));
            tc.verifyEqual(plan.FrameCounterOffset, 0);
            tc.verifyEqual(plan.GpioOffset, 4);
            tc.verifyEqual(plan.TtlSource, 'embedded');
            tc.verifyEqual(plan.TtlLine, 0);
            tc.verifyEqual(plan.Gate, 'none');
            tc.verifyEqual(tc.Device.SyncPlan, plan);
            tc.verifyEqual(tc.NM.get('TriggerMode'), 'Off');
        end

        function passiveWithoutFrameCounter(tc)
            plan = spincam.SyncController('passive', 'EmbedFrameCounter', false).apply(tc.Device);
            tc.verifyEqual(tc.Reg.read(tc.FrameInfo), uint32(hex2dec('87FF0100')));
            tc.verifyEqual(plan.GpioOffset, 0);
            tc.verifyEqual(plan.FrameCounterOffset, -1);
        end

        function ttlNoneDoesNotEmbedGpio(tc)
            plan = spincam.SyncController('A', 'TtlSource', 'none').apply(tc.Device);
            tc.verifyEqual(plan.GpioOffset, -1);
            tc.verifyEqual(plan.TtlSource, 'none');
        end

        function triggeredFrameWriteOrder(tc)
            tc.NM.setRaw('TriggerMode', 'On');
            s = spincam.SyncController('triggered', 'TtlLine', 'Line2', 'TriggerActivation', 'FallingEdge');
            plan = s.apply(tc.Device);
            log = tc.NM.WriteLog;
            names = log(:, 1)';
            modeWrites = find(strcmp(names, 'TriggerMode'));
            sourceWrite = find(strcmp(names, 'TriggerSource'));
            tc.verifyEqual(log{modeWrites(1), 2}, 'Off');
            tc.verifyEqual(log{modeWrites(end), 2}, 'On');
            tc.verifyTrue(modeWrites(1) < sourceWrite && sourceWrite < modeWrites(end));
            tc.verifyEqual(tc.NM.get('TriggerSource'), 'Line2');
            tc.verifyEqual(tc.NM.get('TriggerActivation'), 'FallingEdge');
            tc.NM.set('LineSelector', 'Line2');
            tc.verifyEqual(tc.NM.get('LineMode'), 'Input');
            tc.verifyEqual(plan.TtlLine, 2);
            tc.verifyEqual(plan.Gate, 'none');
        end

        function triggeredStartGatesInsteadOfTriggerMode(tc)
            plan = spincam.SyncController('triggered', 'TriggerType', 'start').apply(tc.Device);
            tc.verifyEqual(tc.NM.get('TriggerMode'), 'Off');
            tc.verifyEqual(plan.Gate, 'firstRisingEdge');
        end

        function triggerDelayEnabledWhenRequested(tc)
            spincam.SyncController('B', 'TriggerDelay_us', 250).apply(tc.Device);
            tc.verifyTrue(tc.NM.get('TriggerDelayEnabled'));
            tc.verifyEqual(tc.NM.get('TriggerDelay'), 250);
        end

        function startGateNeedsTtlSource(tc)
            s = spincam.SyncController('triggered', 'TriggerType', 'start', 'TtlSource', 'none');
            tc.verifyError(@() s.apply(tc.Device), 'spincam:sync:gateNeedsTtl');
        end

        function outputOnlyLineCannotBeInput(tc)
            s = spincam.SyncController('triggered', 'TtlLine', 'Line1');
            tc.verifyError(@() s.apply(tc.Device), 'spincam:sync:lineNotInput');
        end

        function strobeEveryNOnOptoOutput(tc)
            s = spincam.SyncController('strobe', 'StrobeLine', 'Line1', 'StrobeEveryN', 4, ...
                'StrobeDuration_us', 2000, 'StrobeInvert', true);
            plan = s.apply(tc.Device);
            tc.verifyEqual(tc.Reg.read(tc.StrpatCtrl), uint32(hex2dec('80000400')));
            tc.verifyEqual(tc.Reg.read(hex2dec('1128')), uint32(hex2dec('80008000')));
            tc.NM.set('LineSelector', 'Line1');
            tc.verifyEqual(tc.NM.get('LineSource'), 'ExposureActive');
            tc.verifyEqual(tc.NM.get('StrobeDuration'), 2000);
            tc.verifyTrue(tc.NM.get('LineInverter'));
            tc.verifyEqual(plan.GpioOffset, 4, 'TTL logging continues in strobe mode');
        end

        function strobeOnLine2SwitchesToOutput(tc)
            spincam.SyncController('C', 'StrobeLine', 'Line2').apply(tc.Device);
            tc.NM.set('LineSelector', 'Line2');
            tc.verifyEqual(tc.NM.get('LineMode'), 'Output');
            tc.verifyEqual(tc.Reg.read(tc.StrpatCtrl), uint32(hex2dec('80000100')));
        end

        function strobeLineConflictsWithTtlLine(tc)
            s = spincam.SyncController('strobe', 'StrobeLine', 'Line2', 'TtlLine', 'Line2');
            tc.verifyError(@() s.apply(tc.Device), 'spincam:sync:lineConflict');
        end

        function badStrobeSource(tc)
            s = spincam.SyncController('strobe', 'StrobeSource', 'Bogus');
            tc.verifyError(@() s.apply(tc.Device), 'spincam:sync:badStrobeSource');
        end

        function everyNNeedsStrobePatternRegister(tc)
            tc.Reg.setRaw(tc.StrpatCtrl, 0);
            s = spincam.SyncController('strobe', 'StrobeEveryN', 3);
            tc.verifyError(@() s.apply(tc.Device), 'spincam:sync:noStrobePattern');
        end

        function fallsBackToPolledWithoutEmbeddedGpio(tc)
            tc.Reg.setRaw(tc.FrameInfo, hex2dec('80000000'));
            s = spincam.SyncController('passive');
            plan = tc.verifyWarning(@() s.apply(tc.Device), 'spincam:sync:embeddedUnavailable');
            tc.verifyEqual(plan.TtlSource, 'polled');
            tc.verifyEqual(plan.GpioOffset, -1);
        end

        function resetRestoresDefaults(tc)
            spincam.SyncController('strobe', 'StrobeLine', 'Line2', 'StrobeEveryN', 5).apply(tc.Device);
            spincam.SyncController.reset(tc.Device);
            tc.verifyEqual(tc.Reg.read(tc.FrameInfo), uint32(hex2dec('87FF0000')));
            tc.verifyEqual(tc.Reg.read(tc.StrpatCtrl), uint32(hex2dec('80000100')));
            tc.verifyEqual(tc.Reg.read(hex2dec('1138')), uint32(hex2dec('8000FFFF')));
            tc.NM.set('LineSelector', 'Line2');
            tc.verifyEqual(tc.NM.get('LineMode'), 'Input');
            tc.verifyEqual(tc.Device.SyncPlan.TtlSource, 'none');
        end

        function optionsForListsFieldsUsedByEachMode(tc)
            f = @spincam.SyncController.optionsFor;
            tc.verifyEqual(f('passive'), {'Mode', 'TtlSource', 'TtlLine', 'EmbedFrameCounter'});
            triggered = f('B');
            tc.verifyTrue(all(ismember({'TtlLine', 'TriggerType', 'TriggerActivation', 'ExposureMode', ...
                'TriggerDelay_us'}, triggered)));
            tc.verifyFalse(any(ismember({'StrobeLine', 'StrobeEveryN'}, triggered)));
            strobe = f('strobe');
            tc.verifyTrue(all(ismember({'TtlLine', 'StrobeLine', 'StrobeSource', 'StrobeEveryN', ...
                'StrobeDuration_us', 'StrobeDelay_us', 'StrobeInvert'}, strobe)));
            tc.verifyFalse(any(ismember({'TriggerType', 'TriggerActivation'}, strobe)));
            tc.verifyFalse(ismember('TtlLine', f('passive', 'none')));
            tc.verifyTrue(ismember('TtlLine', f('triggered', 'none')), 'Trigger mode always uses TtlLine');
            tc.verifyTrue(all(ismember([f('passive'), triggered, strobe], properties(spincam.SyncController))));
        end

        function optionParsing(tc)
            tc.verifyEqual(spincam.SyncController('B').Mode, 'triggered');
            tc.verifyEqual(spincam.SyncController('c').Mode, 'strobe');
            tc.verifyEqual(spincam.SyncController('passive', 'ttlline', 3).TtlLine, 'Line3');
            tc.verifyError(@() spincam.SyncController('passive', 'Nope', 1), 'spincam:sync:unknownOption');
            tc.verifyError(@() spincam.SyncController('sideways'), 'spincam:sync:badValue');
        end
    end
end
