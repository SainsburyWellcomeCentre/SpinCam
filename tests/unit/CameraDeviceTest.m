classdef CameraDeviceTest < matlab.unittest.TestCase
    %CAMERADEVICETEST Property side effects, clamping and settings round-trips (no engine).

    properties
        NM
        Device
    end

    methods (TestMethodSetup)
        function create(tc)
            tc.NM = spincam.internal.MockNodeMap.cm3();
            tc.Device = tc.makeDevice(tc.NM);
        end
    end

    methods (Test)
        function frameRateSwitchesAutoOffFirst(tc)
            actual = tc.Device.set('FrameRate', 60);
            tc.verifyEqual(actual, 60);
            tc.verifyEqual(tc.NM.writtenNames(), {'AcquisitionFrameRateAuto', 'AcquisitionFrameRate'});
            tc.verifyEqual(tc.NM.get('AcquisitionFrameRateAuto'), 'Off');
        end

        function exposureClampedToFramePeriod(tc)
            tc.Device.set('FrameRate', 100);
            actual = tc.verifyWarning(@() tc.Device.set('ExposureTime', 50000), 'spincam:property:clamped');
            tc.verifyEqual(actual, 9908, 'AbsTol', 0.01);
            tc.verifyEqual(tc.NM.get('ExposureAuto'), 'Off');
        end

        function aliasesMapToNodes(tc)
            tc.Device.set('Brightness', 5);
            tc.verifyEqual(tc.NM.get('BlackLevel'), 5);
            tc.Device.set('Shutter', 1000);
            tc.verifyEqual(tc.NM.get('ExposureTime'), 1000);
            tc.verifyEqual(tc.Device.get('Exposure'), 1000);
        end

        function gammaUnavailableOnCm3Firmware(tc)
            tc.verifyError(@() tc.Device.set('Gamma', 1.2), 'spincam:property:unavailable');
        end

        function gammaEnabledBeforeWriteWhenAvailable(tc)
            nm = spincam.internal.MockNodeMap.cm3('GammaAvailable', true);
            dev = tc.makeDevice(nm);
            dev.set('Gamma', 1.5);
            tc.verifyEqual(nm.writtenNames(), {'GammaEnabled', 'Gamma'});
            tc.verifyTrue(nm.get('GammaEnabled'));
        end

        function enumValuesCaseInsensitive(tc)
            tc.verifyEqual(tc.Device.set('ExposureAuto', 'off'), 'Off');
            tc.verifyError(@() tc.Device.set('GainAuto', 'Sometimes'), 'spincam:property:badValue');
        end

        function integersRoundedToIncrement(tc)
            tc.verifyEqual(tc.Device.set('Width', 1000), 1008);
        end

        function rawNodePassthroughAndUnknownNames(tc)
            tc.verifyEqual(tc.Device.set('TriggerDelay', 100), 100);
            tc.verifyError(@() tc.Device.set('NoSuchThing', 1), 'spincam:property:unknown');
        end

        function settingsRoundTrip(tc)
            tc.Device.set('FrameRate', 50);
            tc.Device.set('Gain', 3);
            tc.Device.set('BlackLevel', 4);
            s = tc.Device.getSettings();
            nm2 = spincam.internal.MockNodeMap.cm3();
            dev2 = tc.makeDevice(nm2);
            dev2.applySettings(s);
            tc.verifyEqual(dev2.get('FrameRate'), 50);
            tc.verifyEqual(dev2.get('Gain'), 3);
            tc.verifyEqual(dev2.get('BlackLevel'), 4);
            tc.verifyEqual(dev2.get('ExposureAuto'), 'Continuous');
            tc.verifyFalse(isfield(s, 'Gamma'));
        end

        function cropResetsOffsetsBeforeSize(tc)
            dev = tc.Device;
            tc.verifyEqual(dev.setRoi([104 50 640 480]), [104 50 640 480]);
            tc.NM.clearLog();
            tc.verifyEqual(dev.resetRoi(), [0 0 1280 1024]);
            tc.verifyEqual(tc.NM.writtenNames(), {'OffsetX', 'OffsetY', 'Width', 'Height'}, ...
                'Offsets must be cleared before the size can grow');
        end

        function cropAlignedToIncrementsAndCentred(tc)
            actual = tc.verifyWarning(@() tc.Device.setRoi([0 0 1000 701], 'Center', true), 'spincam:roi:adjusted');
            tc.verifyEqual(actual, [144 162 992 700]);
            tc.verifyEqual(tc.Device.sensorSize(), [1280 1024]);
        end

        function cropKeptInsideSensor(tc)
            actual = tc.verifyWarning(@() tc.Device.setRoi([1000 900 640 480]), 'spincam:roi:adjusted');
            tc.verifyEqual(actual, [640 544 640 480]);
            actual = tc.verifyWarning(@() tc.Device.setRoi([3 3 640 480]), 'spincam:roi:adjusted');
            tc.verifyEqual(actual, [0 2 640 480], 'OffsetX rounds down to multiples of 8');
        end

        function applySettingsRestoresAnyCrop(tc)
            tc.Device.setRoi([200 100 640 480]);
            s = tc.Device.getSettings();
            nm2 = spincam.internal.MockNodeMap.cm3();
            dev2 = tc.makeDevice(nm2);
            dev2.setRoi([640 544 640 480]);
            dev2.applySettings(s);
            tc.verifyEqual(dev2.getRoi(), [200 100 640 480]);
        end

        function describePropertiesCoversRegistry(tc)
            T = tc.Device.describeProperties();
            tc.verifyEqual(height(T), numel(spincam.internal.PropertyRegistry.all()));
            tc.verifyFalse(T.Available(strcmp(T.Name, 'Gamma')));
            tc.verifyEqual(T.Auto{strcmp(T.Name, 'Gain')}, 'Continuous');
        end

        function streamingNeedsEngine(tc)
            tc.verifyError(@() tc.Device.startStream(), 'spincam:stream:unavailable');
        end
    end

    methods (Static, Access = private)
        function dev = makeDevice(nm)
            dev = spincam.CameraDevice('24226887', nm, spincam.internal.MockNodeMap.cm3Stream(), ...
                spincam.internal.MockRegisterPort('24226887'), [], true);
        end
    end
end
