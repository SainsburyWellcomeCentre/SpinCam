classdef HardwareSmokeTest < matlab.unittest.TestCase
    %HARDWARESMOKETEST Attached Chameleon3 cameras (SpinView must be closed).
    %   Restores camera settings and sync state in teardown. Never switches Line2/Line3
    %   to outputs (only Line1, which is an output by hardware, is used for strobe).

    properties
        Manager
        OutDir
    end

    methods (TestClassSetup)
        function connect(tc)
            tc.assumeTrue(ispc && NET.isNETSupported, 'Requires Windows with .NET.');
            tc.assumeNotEmpty(spincam.internal.NativeEngine.spinnakerBin(), 'Requires Spinnaker.');
            % FrameRate [] keeps connect() from changing the cameras before their settings
            % are snapshotted for restoring.
            cm = spincam.CameraManager('FrameRate', []);
            if height(cm.listCameras()) == 0
                delete(cm);
                tc.assumeFail('No cameras attached.');
            end
            cm.connect();
            tc.Manager = cm;
            tc.addTeardown(@() delete(cm));
            original = arrayfun(@(d) {d.getSettings()}, cm.Cameras);
            triggers = arrayfun(@(d) {snapshotNodes(d, triggerNodes())}, cm.Cameras);
            tc.addTeardown(@() restoreSettings(cm, original, triggers));
            tc.OutDir = fullfile(spincam.internal.NativeEngine.projectRoot(), 'tests', '_output', ...
                sprintf('HardwareSmokeTest_%s', char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'))));
            mkdir(tc.OutDir);
            tc.addTeardown(@() rmdir(tc.OutDir, 's'));
        end
    end

    methods (TestMethodTeardown)
        function backToIdlePassive(tc)
            cm = tc.Manager;
            if strcmp(cm.State, 'recording')
                cm.stopRecording();
            end
            if strcmp(cm.State, 'preview')
                cm.stopPreview();
            end
            cm.configureSync('passive');
        end
    end

    methods (Test)
        function identity(tc)
            for dev = tc.Manager.Cameras
                tc.verifyNotEmpty(dev.Serial);
                tc.verifyNotEmpty(dev.Model);
                tc.verifyNotEmpty(dev.Firmware);
            end
        end

        function propertyRoundTrips(tc)
            cm = tc.Manager;
            tc.verifyEqual(cm.setProperty('FrameRate', 60), 60 * ones(1, numel(cm.Cameras)), 'AbsTol', 0.5);
            tc.verifyEqual(cm.setProperty('ExposureTime', 5000), 5000 * ones(1, numel(cm.Cameras)), 'AbsTol', 5);
            tc.verifyEqual(cm.setProperty('Gain', 1), ones(1, numel(cm.Cameras)), 'AbsTol', 0.2);
            tc.verifyEqual(cm.setProperty('BlackLevel', 2), 2 * ones(1, numel(cm.Cameras)), 'AbsTol', 0.2);
            tc.verifyEqual(cm.getProperty('ExposureAuto'), repmat({'Off'}, 1, numel(cm.Cameras)));
        end

        function registersMatchVerifiedLayout(tc)
            F = spincam.internal.FrameInfo;
            P = spincam.internal.StrobePattern;
            for dev = tc.Manager.Cameras
                fi = dev.Registers.read(F.RegisterOffset);
                tc.verifyTrue(F.isSupported(fi, 'GPIO'));
                tc.verifyTrue(F.isSupported(fi, 'FrameCounter'));
                tc.verifyTrue(P.isPresent(dev.Registers.read(P.CtrlOffset)));
                tc.verifyEqual(dev.Registers.read(hex2dec('1F20')), uint32(str2double(dev.Serial)));
            end
        end

        function previewDeliversFrames(tc)
            cm = tc.Manager;
            cm.setProperty('FrameRate', 60);
            cm.setProperty('ExposureTime', 5000);
            cm.startPreview();
            pause(2);
            [frames, meta] = cm.getLatestFrames();
            S = cm.getStats();
            for k = 1:numel(frames)
                tc.verifyEqual(size(frames{k}), [meta(k).Height meta(k).Width]);
                tc.verifyGreaterThan(meta(k).Width, 0);
            end
            tc.verifyEqual(S.FPS, 60 * ones(height(S), 1), 'RelTol', 0.2);
            tc.verifyFalse(any(S.Faulted));
            tc.verifyLessThanOrEqual(S.FramesMissed, 0.01 * S.FramesReceived);
        end

        function passiveRecordingWithEmbeddedTtl(tc)
            % Default acquisition: passive sync at 100 fps on both cameras.
            cm = tc.Manager;
            cm.setProperty('FrameRate', 100);
            cm.setProperty('ExposureTime', 5000);
            cm.configureSync('passive', 'TtlLine', 'Line0');
            cm.Recorder.Format = 'avi-mjpeg';
            plan = cm.startRecording(tc.OutDir, 'passive');
            pause(3);
            s = cm.stopRecording();
            for c = s.Cameras
                tc.verifyEmpty(c.Error);
                tc.verifyEqual(c.FramesLogged, 300, 'RelTol', 0.2);
                tc.verifyLessThanOrEqual(c.FramesMissed, 2);
                tc.verifyEqual(c.VideoFiles, {strrep(c.CsvFile, '.csv', '.avi')}, 'Video and CSV share a name');
                tc.verifyTrue(startsWith(fileName(c.CsvFile), [c.Name '_passive_']));
                T = spincam.io.readFrameLog(c.CsvFile);
                tc.verifyTrue(all(ismember(T.TTL_State, [0 1])), 'Embedded GPIO decoded for every frame');
                tc.verifyTrue(all(T.TTL_Source == "embedded"));
                tc.verifyEqual(bitand(T.GPIO_LineStatus, 1), T.TTL_State, 'TTL_State is Line0 of the GPIO word');
                tc.verifyEqual(diff(T.EmbeddedFrameCounter), 1 + T.FramesMissedBefore(2:end));
                tc.verifyEqual(median(diff(T.HardwareTimestamp_us)), 1e6 / 100, 'RelTol', 0.05);
                reader = VideoReader(c.VideoFiles{1});
                tc.verifyEqual(reader.NumFrames, c.FramesWritten);
            end
            tc.verifyTrue(isfile(plan.EventsFile) && isfile(plan.SessionFile));
        end

        function cropRecordsSmallerFramesWithEmbeddedTtl(tc)
            cm = tc.Manager;
            original = cm.getRoi();
            tc.addTeardown(@() restoreRoi(cm, original));
            cm.setProperty('FrameRate', 120);
            actual = cm.setRoi([0 0 1024 900], [], 'Center', true);
            tc.verifyEqual(actual, repmat([128 62 1024 900], numel(cm.Cameras), 1));
            cm.configureSync('passive');
            cm.Recorder.Format = 'avi-mjpeg';
            cm.startRecording(tc.OutDir, 'crop');
            pause(3);
            s = cm.stopRecording();
            for c = s.Cameras
                tc.verifyEmpty(c.Error);
                tc.verifyEqual(c.WriterDrops, 0);
                tc.verifyLessThanOrEqual(c.FramesMissed, 2);
                reader = VideoReader(c.VideoFiles{1});
                tc.verifyEqual([reader.Width reader.Height], [1024 900]);
                tc.verifyEqual(reader.NumFrames, c.FramesWritten);
                T = spincam.io.readFrameLog(c.CsvFile);
                tc.verifyTrue(all(ismember(T.TTL_State, [0 1])), 'Embedded GPIO decoded from cropped frames');
                tc.verifyEqual(median(diff(T.HardwareTimestamp_us)), 1e6 / 120, 'RelTol', 0.05);
            end
        end

        function triggeredModeConfiguresCamera(tc)
            cm = tc.Manager;
            cm.configureSync('triggered', 'TriggerType', 'frame', 'TtlLine', 'Line0');
            for dev = cm.Cameras
                tc.verifyEqual(dev.get('TriggerMode'), 'On');
                tc.verifyEqual(dev.get('TriggerSource'), 'Line0');
                tc.verifyEqual(dev.get('TriggerActivation'), 'RisingEdge');
            end
            cm.Recorder.Format = 'none';
            cm.startRecording(tc.OutDir, 'triggered');
            pause(1.5);
            s = cm.stopRecording();
            tc.verifyEmpty([s.Cameras.Error]);
            % Frames appear only if TTL pulses arrive on Line0; report rather than assume.
            fprintf('Triggered mode frames logged (depends on external pulses): %s\n', mat2str([s.Cameras.FramesLogged]));
        end

        function strobeOnOptoOutputUsesPatternRegisters(tc)
            cm = tc.Manager;
            cm.configureSync('strobe', 'StrobeLine', 'Line1', 'StrobeEveryN', 2);
            P = spincam.internal.StrobePattern;
            for dev = cm.Cameras
                tc.verifyEqual(P.period(dev.Registers.read(P.CtrlOffset)), 2);
                tc.verifyEqual(P.maskSlots(dev.Registers.read(P.maskOffset(1))), 0);
            end
            cm.configureSync('passive');
            for dev = cm.Cameras
                tc.verifyEqual(P.period(dev.Registers.read(P.CtrlOffset)), 1);
            end
        end

        function repeatedStartStop(tc)
            cm = tc.Manager;
            for k = 1:3
                cm.startPreview();
                pause(0.5);
                cm.stopPreview();
            end
            S = cm.getStats();
            tc.verifyFalse(any(S.Faulted));
        end
    end
end

function restoreSettings(cm, original, triggers)
if ~isvalid(cm)
    return
end
if strcmp(cm.State, 'recording')
    cm.stopRecording();
end
if strcmp(cm.State, 'preview')
    cm.stopPreview();
end
for k = 1:min(numel(original), numel(cm.Cameras))
    dev = cm.Cameras(k);
    try
        dev.applySettings(original{k});
        dev.NodeMap.setIfDifferent('TriggerMode', 'Off');
        names = fieldnames(triggers{k});
        for n = 1:numel(names)
            if dev.NodeMap.isWritable(names{n})
                dev.NodeMap.setIfDifferent(names{n}, triggers{k}.(names{n}));
            end
        end
    catch me
        warning('spincam:test:restoreFailed', 'Restoring %s: %s', dev.Serial, me.message);
    end
end
end

function restoreRoi(cm, original)
if ~isvalid(cm)
    return
end
if strcmp(cm.State, 'recording')
    cm.stopRecording();
end
if strcmp(cm.State, 'preview')
    cm.stopPreview();
end
for k = 1:min(size(original, 1), numel(cm.Cameras))
    cm.Cameras(k).setRoi(original(k, :));
end
end

function name = fileName(path)
[~, stem, ext] = fileparts(path);
name = [stem ext];
end

function names = triggerNodes()
names = {'TriggerSelector', 'TriggerSource', 'TriggerActivation', 'ExposureMode', 'TriggerDelayEnabled'};
end

function s = snapshotNodes(dev, names)
s = struct();
for n = 1:numel(names)
    if dev.NodeMap.has(names{n}) && dev.NodeMap.isReadable(names{n})
        s.(names{n}) = dev.NodeMap.get(names{n});
    end
end
end
