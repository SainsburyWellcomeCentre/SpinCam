classdef CameraManagerMockTest < matlab.unittest.TestCase
    %CAMERAMANAGERMOCKTEST End-to-end headless API with the mock backend.

    properties
        OutDir
        Manager
    end

    properties (Constant)
        Half = 10
        Fps = 50
    end

    methods (TestClassSetup)
        function requireEngine(tc)
            tc.assumeTrue(ispc && NET.isNETSupported, 'Requires Windows with .NET.');
            tc.assumeNotEmpty(spincam.internal.NativeEngine.spinnakerBin(), 'Requires Spinnaker assemblies.');
            spincam.internal.NativeEngine.load();
        end
    end

    methods (TestMethodSetup)
        function create(tc)
            tc.OutDir = fullfile(spincam.internal.NativeEngine.projectRoot(), 'tests', '_output', ...
                sprintf('CameraManagerMockTest_%s_%d', char(datetime('now', 'Format', 'HHmmssSSS')), randi(1e6)));
            mkdir(tc.OutDir);
            tc.Manager = spincam.CameraManager('Backend', 'mock', 'NumCameras', 2, 'FrameRate', tc.Fps, ...
                'Resolution', [240 320], 'TtlHalfPeriodFrames', tc.Half);
            tc.addTeardown(@() delete(tc.Manager));
            tc.addTeardown(@() rmdirIfExists(tc.OutDir));
        end
    end

    methods (Test)
        function listAndConnect(tc)
            cm = tc.Manager;
            T = cm.listCameras();
            tc.verifyEqual(height(T), 2);
            tc.verifyFalse(any(T.Connected));
            cm.connect();
            T = cm.listCameras();
            tc.verifyTrue(all(T.Connected));
            tc.verifyEqual(cm.camera(2).Serial, T.Serial{2});
            tc.verifyEqual(cm.camera(T.Serial{1}).Serial, T.Serial{1});
            tc.verifyError(@() cm.connect({'nope'}), 'spincam:manager:cameraNotFound');
        end

        function passiveRecordingEndToEnd(tc)
            cm = tc.Manager;
            cm.connect();
            cm.setProperty('Gain', 2);
            cm.configureSync('passive');
            cm.Recorder.Format = 'avi-mjpeg';
            plan = cm.startRecording(tc.OutDir, 'run1');
            tc.verifyEqual(cm.State, 'recording');
            cm.logEvent('TrialStart', 1);
            pause(1.5);
            cm.logEvent('Note', 'with, comma');
            s = cm.stopRecording();
            tc.verifyEqual(cm.State, 'idle');

            tc.verifyNumElements(s.Cameras, 2);
            tc.verifyTrue(startsWith(s.BaseName, 'run1_'));
            names = {'topview', 'sideview'};
            for k = 1:2
                c = s.Cameras(k);
                tc.verifyEmpty(c.Error);
                tc.verifyEqual(c.Name, names{k});
                tc.verifyEqual(c.CsvFile, fullfile(tc.OutDir, [names{k} '_' s.BaseName '.csv']));
                tc.verifyEqual(c.VideoFiles, {strrep(c.CsvFile, '.csv', '.avi')}, 'Video renamed to match the CSV');
                tc.verifyEmpty(dir(fullfile(tc.OutDir, '*-0000.avi')));
                tc.verifyGreaterThan(c.FramesLogged, 0.6 * 1.5 * tc.Fps);
                tc.verifyEqual(c.FramesWritten, c.FramesLogged);
                tc.verifyTrue(isfile(c.VideoFiles{1}));
                tc.verifyEqual(VideoReader(c.VideoFiles{1}).NumFrames, c.FramesWritten);
                T = spincam.io.readFrameLog(c.CsvFile);
                tc.verifyEqual(height(T), c.FramesLogged);
                tc.verifyEqual(T.TTL_State, mod(floor(T.EmbeddedFrameCounter / tc.Half), 2));
                tc.verifyTrue(all(T.CameraID == string(c.Serial)));
                tc.verifyEqual(plan.Cameras(k).CsvFile, c.CsvFile);
                tc.verifyEqual(plan.Cameras(k).VideoFile, c.VideoFiles{1});
            end

            merged = spincam.io.mergeFrameLogs(tc.OutDir, s.BaseName);
            tc.verifyEqual(height(merged), sum([s.Cameras.FramesLogged]));
            tc.verifyTrue(issorted(merged.HostTime_s));
            tc.verifyEqual(sort(unique(merged.Name))', ["sideview", "topview"]);
            tc.verifyEqual(spincam.io.mergeFrameLogs(s), merged);
            tc.verifyEqual(s.EventsFile, fullfile(tc.OutDir, [s.BaseName '_events.csv']));

            E = spincam.io.readEventLog(s.EventsFile);
            tc.verifyEqual(E.Event', ["RecordingStart", "TrialStart", "Note", "RecordingStop"]);
            tc.verifyEqual(E.Value(3), "with, comma");
            trial = E.HostTime_s(E.Event == "TrialStart");
            tc.verifyGreaterThan(trial, min(merged.HostTime_s) - 0.5);
            tc.verifyLessThan(trial, max(merged.HostTime_s));

            session = jsondecode(fileread(s.SessionFile));
            tc.verifyEqual(session.Sync.Mode, 'passive');
            tc.verifyEqual(session.Summary.Cameras(1).FramesLogged, s.Cameras(1).FramesLogged);
            cameras = session.Cameras;
            if iscell(cameras)
                cameras = [cameras{:}];
            end
            tc.verifyEqual(cameras(1).Settings.Gain, 2);
            tc.verifyEqual(cameras(2).Name, 'sideview');
        end

        function defaultFormatEncodesOnSeveralCores(tc)
            cm = tc.Manager;
            cm.connect();
            tc.verifyEqual(cm.Recorder.Format, 'avi-mjpeg-mt');
            cm.Recorder.EncoderThreads = 3;
            cm.startRecording(tc.OutDir, 'mt');
            pause(1.0);
            s = cm.stopRecording();
            for k = 1:2
                c = s.Cameras(k);
                tc.verifyEmpty(c.Error);
                tc.verifyEqual(c.VideoFiles, {strrep(c.CsvFile, '.csv', '.avi')});
                tc.verifyGreaterThan(c.FramesWritten, 0);
                tc.verifyEqual(c.FramesWritten, c.FramesLogged);
                tc.verifyEqual(VideoReader(c.VideoFiles{1}).NumFrames, c.FramesWritten);
            end
            session = jsondecode(fileread(s.SessionFile));
            tc.verifyEqual(session.Recorder.EncoderThreads, 3);
        end

        function fileNamesCombineCameraNameFileNameAndDateTime(tc)
            cm = tc.Manager;
            cm.connect();
            cm.setCameraName(1, 'top view!');
            when = datetime(2026, 9, 15, 14, 30, 12);
            n = cm.plannedFileNames('m01', when);
            tc.verifyEqual(n.Cameras, {'top_view_m01_20260915_143012', 'sideview_m01_20260915_143012'});
            tc.verifyEqual(n.Shared, 'm01_20260915_143012');
            n = cm.plannedFileNames('', when);
            tc.verifyEqual(n.Cameras{2}, 'sideview_20260915_143012');
            cm.AppendDateTime = false;
            n = cm.plannedFileNames('m01', when);
            tc.verifyEqual(n.Cameras, {'top_view_m01', 'sideview_m01'});
            n = cm.plannedFileNames('', when);
            tc.verifyEqual(n.Cameras, {'top_view', 'sideview'});
            tc.verifyEqual(n.Shared, 'recording');
        end

        function sessionFolderUnderDataRoot(tc)
            cm = tc.Manager;
            tc.verifyEqual(cm.DataRoot, 'D:\videoData');
            tc.verifyEqual(cm.sessionFolder('mouse01', 'day1'), 'D:\videoData\mouse01\day1');
            tc.verifyEqual(cm.sessionFolder('mouse01'), 'D:\videoData\mouse01');
            tc.verifyError(@() cm.sessionFolder('  '), 'spincam:manager:noSubject');
            cm.DataRoot = tc.OutDir;
            cm.connect(1);
            cm.Recorder.Format = 'none';
            plan = cm.startRecording(cm.sessionFolder('m02', 's1'), 'm02');
            pause(0.2);
            cm.stopRecording();
            tc.verifyEqual(plan.Folder, fullfile(tc.OutDir, 'm02', 's1'));
            tc.verifyTrue(isfile(plan.Cameras(1).CsvFile));
        end

        function cameraNamesDefaultByserialAndAreRemembered(tc)
            cm = tc.Manager;
            T = cm.listCameras();
            cm.connect(2);
            tc.verifyEqual(cm.camera(1).Name, 'sideview', 'Default follows serial order, not connect order');
            cm.connect(1);
            tc.verifyEqual(cm.camera(T.Serial{1}).Name, 'topview');
            tc.verifyEqual(cm.camera('sideview').Serial, T.Serial{2});
            tc.verifyEqual(cm.listCameras().Name, {'topview'; 'sideview'});
            tc.verifyError(@() cm.setCameraName('topview', 'SideView'), 'spincam:manager:duplicateCameraName');
            tc.verifyError(@() cm.setCameraName('topview', '  '), 'spincam:manager:badCameraName');
            cm.setCameraName(T.Serial{2}, 'side2');
            cm.disconnect();
            cm.connect();
            tc.verifyEqual(cm.camera(T.Serial{2}).Name, 'side2');
            cm.setProperty('Gain', 4, {'side2'});
            tc.verifyEqual(cm.camera(T.Serial{2}).get('Gain'), 4);
        end

        function cropRecordsCroppedFrames(tc)
            cm = tc.Manager;
            cm.connect(1);
            cm.Recorder.Format = 'raw';
            cm.startPreview();
            tc.verifyEqual(cm.setRoi([0 0 160 120], [], 'Center', true), [80 60 160 120]);
            tc.verifyEqual(cm.State, 'preview', 'Cropping restarts preview');
            pause(0.5);
            frames = cm.getLatestFrames();
            tc.verifySize(frames{1}, [120 160]);
            cm.startRecording(tc.OutDir, 'crop');
            tc.verifyError(@() cm.setRoi([0 0 64 64]), 'spincam:manager:recording');
            pause(0.8);
            s = cm.stopRecording();
            c = s.Cameras(1);
            reader = spincam.io.RawVideoReader(c.VideoFiles{1});
            tc.verifyEqual([reader.Height reader.Width], [120 160]);
            tc.verifyEqual(reader.NumFrames, c.FramesWritten);
            delete(reader);
            T = spincam.io.readFrameLog(c.CsvFile);
            tc.verifyEqual(T.TTL_State, mod(floor(T.EmbeddedFrameCounter / tc.Half), 2), ...
                'Embedded TTL is decoded from cropped frames');
            session = jsondecode(fileread(s.SessionFile));
            cameras = session.Cameras;
            if iscell(cameras)
                cameras = [cameras{:}];
            end
            tc.verifyEqual([cameras(1).Settings.OffsetX, cameras(1).Settings.Width], [80 160]);
            cm.stopPreview();
            tc.verifyEqual(cm.resetRoi(), [0 0 320 240]);
            tc.verifyEqual(cm.getRoi(), [0 0 320 240]);
        end

        function defaultFrameRateAppliedOnConnect(tc)
            cm = spincam.CameraManager('Backend', 'mock', 'NumCameras', 1, 'Resolution', [240 320]);
            closer = onCleanup(@() delete(cm));
            tc.verifyEqual(cm.DefaultFrameRate, 100);
            cm.connect();
            tc.verifyEqual(cm.getProperty('FrameRate'), 100, 'AbsTol', 0.5);
            tc.verifyEqual(cm.getProperty('FrameRateAuto'), {'Off'});

            keep = spincam.CameraManager('Backend', 'mock', 'NumCameras', 1, 'Resolution', [240 320], ...
                'FrameRate', []);
            closer2 = onCleanup(@() delete(keep));
            keep.connect();
            tc.verifyEqual(keep.getProperty('FrameRateAuto'), {'Continuous'}, 'FrameRate [] leaves the camera alone');
        end

        function matlabVideoWriterFormat(tc)
            cm = tc.Manager;
            cm.connect(1);
            cm.Recorder.Format = 'matlab-avi';
            cm.startRecording(tc.OutDir, 'mw');
            pause(1.0);
            s = cm.stopRecording();
            c = s.Cameras(1);
            tc.verifyEqual(c.WriterDrops, 0);
            reader = VideoReader(c.VideoFiles{1});
            tc.verifyEqual(reader.NumFrames, c.FramesWritten);
            tc.verifyEqual([reader.Height reader.Width], [240 320]);
        end

        function triggeredStartGate(tc)
            cm = tc.Manager;
            cm.connect(1);
            cm.configureSync('triggered', 'TriggerType', 'start');
            cm.Recorder.Format = 'none';
            cm.startRecording(tc.OutDir, 'gate');
            pause(1.5);
            s = cm.stopRecording();
            tc.verifyTrue(s.Cameras(1).GateOpened);
            T = spincam.io.readFrameLog(s.Cameras(1).CsvFile);
            tc.verifyEqual(T.TTL_State(1), 1);
            tc.verifyEqual(mod(T.EmbeddedFrameCounter(1), tc.Half), 0);
        end

        function previewFramesAndStats(tc)
            cm = tc.Manager;
            cm.connect();
            cm.startPreview();
            tc.verifyEqual(cm.State, 'preview');
            pause(0.8);
            [frames, meta] = cm.getLatestFrames();
            tc.verifyNumElements(frames, 2);
            tc.verifySize(frames{1}, [240 320]);
            tc.verifyClass(frames{1}, 'uint8');
            tc.verifyEqual([meta.Width], [320 320]);
            S = cm.getStats();
            tc.verifyEqual(height(S), 2);
            tc.verifyTrue(all(S.Running));
            tc.verifyEqual(S.FPS, [tc.Fps; tc.Fps], 'RelTol', 0.3);
            cm.stopPreview();
            tc.verifyEqual(cm.State, 'idle');
        end

        function recordingFromPreviewReturnsToPreview(tc)
            cm = tc.Manager;
            cm.connect(1);
            cm.Recorder.Format = 'none';
            cm.startPreview();
            cm.startRecording(tc.OutDir, 'fromPreview');
            pause(0.3);
            cm.stopRecording();
            tc.verifyEqual(cm.State, 'preview');
            tc.verifyTrue(cm.getStats().Running);
        end

        function syncChangesRefusedWhileRecording(tc)
            cm = tc.Manager;
            cm.connect(1);
            cm.Recorder.Format = 'none';
            cm.startRecording(tc.OutDir, 'busy');
            tc.verifyError(@() cm.configureSync('strobe'), 'spincam:manager:recording');
            tc.verifyError(@() cm.setProperty('Width', 160), 'spincam:manager:recording');
            cm.stopRecording();
        end

        function existingFilesProtected(tc)
            cm = tc.Manager;
            cm.connect(1);
            cm.AppendDateTime = false;
            cm.Recorder.Format = 'raw';
            s = cm.startRecording(tc.OutDir, 'dup');
            pause(0.2);
            cm.stopRecording();
            tc.verifyEqual(cm.LastRecording.Cameras(1).VideoFiles, {strrep(s.Cameras(1).CsvFile, '.csv', '.raw')});
            delete(s.Cameras(1).CsvFile);
            delete(s.EventsFile);
            delete(s.SessionFile);
            tc.verifyError(@() cm.startRecording(tc.OutDir, 'dup'), 'spincam:manager:filesExist', ...
                'An existing .raw file alone blocks the recording');
            tc.verifyEqual(cm.State, 'idle');
            cm.Overwrite = true;
            cm.startRecording(tc.OutDir, 'dup');
            pause(0.2);
            s = cm.stopRecording();
            tc.verifyGreaterThan(s.Cameras(1).FramesLogged, 0);
        end

        function wslPathsAccepted(tc)
            cm = tc.Manager;
            cm.connect(1);
            cm.Recorder.Format = 'none';
            drive = lower(tc.OutDir(1));
            wslFolder = ['/mnt/' drive strrep(tc.OutDir(3:end), '\', '/')];
            plan = cm.startRecording(wslFolder, 'wsl');
            pause(0.2);
            cm.stopRecording();
            tc.verifyEqual(plan.Folder, tc.OutDir);
            tc.verifyTrue(isfile(plan.Cameras(1).CsvFile));
        end

        function dropsReportedInSummary(tc)
            cm = spincam.CameraManager('Backend', 'mock', 'NumCameras', 1, 'FrameRate', 100, ...
                'Resolution', [240 320], 'DropEvery', 9);
            closer = onCleanup(@() delete(cm));
            cm.connect();
            cm.Recorder.Format = 'none';
            cm.startRecording(tc.OutDir, 'drops');
            pause(1.0);
            s = cm.stopRecording();
            T = spincam.io.readFrameLog(s.Cameras(1).CsvFile);
            tc.verifyGreaterThan(s.Cameras(1).FramesMissed, 3);
            tc.verifyEqual(s.Cameras(1).FramesMissed, sum(T.FramesMissedBefore));
        end

        function disconnectResetsCameraState(tc)
            cm = tc.Manager;
            cm.connect(1);
            cm.configureSync('strobe', 'StrobeLine', 'Line2', 'StrobeEveryN', 3);
            dev = cm.camera(1);
            reg = dev.Registers;
            tc.verifyEqual(spincam.internal.StrobePattern.period(reg.read(hex2dec('110C'))), 3);
            cm.disconnect();
            tc.verifyEqual(reg.read(hex2dec('110C')), uint32(hex2dec('80000100')));
            tc.verifyEqual(reg.read(hex2dec('12F8')), uint32(hex2dec('87FF0000')));
            tc.verifyEmpty(cm.Cameras);
        end
    end
end

function rmdirIfExists(folder)
if isfolder(folder)
    rmdir(folder, 's');
end
end
