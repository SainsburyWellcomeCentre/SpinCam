classdef LiveViewerMockTest < matlab.unittest.TestCase
    %LIVEVIEWERMOCKTEST Smoke test of the live viewer against mock cameras (invisible window).

    properties
        OutDir
    end

    methods (TestClassSetup)
        function requirements(tc)
            tc.assumeTrue(ispc && NET.isNETSupported, 'Requires Windows with .NET.');
            tc.assumeNotEmpty(spincam.internal.NativeEngine.spinnakerBin(), 'Requires Spinnaker assemblies.');
            tc.assumeTrue(spincam.internal.canCreateUIFigure(), 'This session cannot create uifigures.');
            spincam.internal.NativeEngine.load();
        end
    end

    methods (TestMethodSetup)
        function makeOutputFolder(tc)
            tc.OutDir = fullfile(spincam.internal.NativeEngine.projectRoot(), 'tests', '_output', ...
                sprintf('LiveViewerMockTest_%s_%d', char(datetime('now', 'Format', 'HHmmssSSS')), randi(1e6)));
            mkdir(tc.OutDir);
            tc.addTeardown(@() rmdir(tc.OutDir, 's'));
        end
    end

    methods (Test)
        function previewControlsAndRecording(tc)
            v = spincam.LiveViewer('Backend', 'mock', 'NumCameras', 2, 'FrameRate', 30, ...
                'Resolution', [240 320], 'Visible', 'off');
            tc.addTeardown(@() delete(v));
            cm = v.Manager;
            tc.verifyNumElements(cm.Cameras, 2);
            tc.verifyEqual({cm.Cameras.Name}, {'topview', 'sideview'});

            v.togglePreview(true);
            tc.verifyEqual(cm.State, 'preview');
            pause(0.8);
            v.refresh();
            images = v.tileImages();
            tc.verifySize(images{1}, [240 320]);

            v.setProperty('Gain', 3);
            tc.verifyEqual(cm.getProperty('Gain'), [3 3], 'AbsTol', 1e-9);
            v.setTarget(cm.Cameras(2).Serial);
            v.setProperty('BlackLevel', 7);
            tc.verifyEqual(cm.getProperty('BlackLevel'), [1.95312 7], 'AbsTol', 1e-4);
            v.setAuto('ExposureTime', true);
            tc.verifyEqual(cm.camera(2).get('ExposureAuto'), 'Continuous');

            v.setSync('strobe', 'StrobeEveryN', 2);
            tc.verifyEqual(cm.Sync.Mode, 'strobe');
            tc.verifyEqual(cm.Sync.StrobeEveryN, 2);
            tc.verifyEqual(cm.State, 'preview', 'Applying sync restarts preview');

            v.setCameraName(cm.Cameras(2).Serial, 'side cam');
            tc.verifyEqual(cm.Cameras(2).Name, 'side_cam');
            v.setOutput('DataRoot', tc.OutDir, 'Subject', 'mouse01', 'Session', 'day1', 'Format', 'avi-mjpeg');
            folder = fullfile(tc.OutDir, 'mouse01', 'day1');
            tc.verifyEqual(v.outputFolder(), folder);
            v.toggleRecording(true);
            tc.verifyEqual(cm.State, 'recording');
            pause(0.8);
            v.refresh();
            v.toggleRecording(false);
            tc.verifyEqual(cm.State, 'preview');

            s = cm.LastRecording;
            tc.verifyEqual(s.Folder, folder);
            tc.verifyGreaterThan(s.Cameras(1).FramesLogged, 5);
            c = s.Cameras(2);
            [~, stem] = fileparts(c.CsvFile);
            tc.verifyTrue(startsWith(stem, 'side_cam_mouse01_'), 'File name defaults to the subject');
            tc.verifyEqual(c.VideoFiles, {fullfile(folder, [stem '.avi'])});
            tc.verifyTrue(isfile(c.VideoFiles{1}) && isfile(c.CsvFile));

            v.selectCamera(cm.Cameras(2).Serial, false);
            tc.verifyNumElements(cm.Cameras, 1);
            tc.verifyNumElements(v.tileImages(), 1);
        end

        function cropFromCameraTab(tc)
            v = spincam.LiveViewer('Backend', 'mock', 'NumCameras', 2, 'FrameRate', 30, 'Resolution', [240 320], ...
                'Visible', 'off');
            tc.addTeardown(@() delete(v));
            cm = v.Manager;
            v.togglePreview(true);
            v.setTarget(cm.Cameras(2).Serial);
            v.setCrop([0 0 160 120], 'Center', true);
            tc.verifyEqual(cm.getRoi(), [0 0 320 240; 80 60 160 120]);
            tc.verifyEqual(cm.State, 'preview');
            pause(1);
            v.refresh();
            images = v.tileImages();
            tc.verifySize(images{1}, [240 320]);
            tc.verifySize(images{2}, [120 160]);
            v.resetCrop();
            tc.verifyEqual(cm.getRoi(), [0 0 320 240; 0 0 320 240]);
        end

        function syncFieldsFollowMode(tc)
            v = spincam.LiveViewer('Backend', 'mock', 'NumCameras', 1, 'Resolution', [240 320], 'Visible', 'off');
            tc.addTeardown(@() delete(v));
            triggerFields = {'TriggerType', 'TriggerActivation', 'ExposureMode', 'TriggerDelay_us'};
            strobeFields = {'StrobeLine', 'StrobeSource', 'StrobeEveryN', 'StrobeDuration_us', ...
                'StrobeDelay_us', 'StrobeInvert'};

            states = v.syncFieldStates();
            tc.verifyEqual(v.Manager.Sync.Mode, 'passive');
            tc.verifyTrue(states.TtlSource && states.TtlLine);
            tc.verifyFalse(any(cellfun(@(n) states.(n), [triggerFields, strobeFields])));

            v.setSync('triggered', 'TriggerType', 'start');
            states = v.syncFieldStates();
            tc.verifyEqual(v.Manager.Sync.TriggerType, 'start');
            tc.verifyTrue(all(cellfun(@(n) states.(n), triggerFields)));
            tc.verifyFalse(any(cellfun(@(n) states.(n), strobeFields)));

            v.setSync('strobe');
            states = v.syncFieldStates();
            tc.verifyTrue(all(cellfun(@(n) states.(n), strobeFields)));
            tc.verifyFalse(any(cellfun(@(n) states.(n), triggerFields)));

            v.setSync('passive', 'TtlSource', 'none');
            tc.verifyFalse(v.syncFieldStates().TtlLine, 'TTL line is unused without a TTL source');
        end

        function recordingNeedsSubject(tc)
            v = spincam.LiveViewer('Backend', 'mock', 'NumCameras', 1, 'Resolution', [240 320], 'Visible', 'off');
            tc.addTeardown(@() delete(v));
            v.setOutput('DataRoot', tc.OutDir, 'Subject', '', 'Format', 'none');
            v.toggleRecording(true);
            tc.verifyEqual(v.Manager.State, 'idle');
            tc.verifySubstring(v.LastMessage, 'subject');
            tc.verifyEmpty(dir(fullfile(tc.OutDir, '*.csv')));
        end

        function attachedManagerSurvivesViewerClose(tc)
            cm = spincam.CameraManager('Backend', 'mock', 'NumCameras', 1, 'Resolution', [240 320]);
            tc.addTeardown(@() delete(cm));
            cm.connect();
            v = spincam.LiveViewer(cm, 'Visible', 'off');
            v.togglePreview(true);
            delete(v);
            tc.verifyTrue(isvalid(cm));
            tc.verifyEqual(cm.State, 'idle');
            tc.verifyNumElements(cm.Cameras, 1);
        end
    end
end
