classdef CameraManager < handle
    %CAMERAMANAGER Headless multi-camera acquisition API.
    %   cm = spincam.CameraManager()                       real cameras (Spinnaker)
    %   cm = spincam.CameraManager('Backend', 'mock')      simulated cameras
    %
    %   cm.connect();                                      % 100 fps; names topview / sideview
    %   cm.setCameraName('24226887', 'topview');
    %   cm.configureSync('passive', 'TtlLine', 'Line0');
    %   folder = cm.sessionFolder('mouse01', 'day1');      % D:\videoData\mouse01\day1
    %   plan = cm.startRecording(folder, 'mouse01');       % topview_mouse01_<datetime>.avi/.csv
    %   cm.logEvent('TrialStart', 1);
    %   summary = cm.stopRecording();
    %   delete(cm)
    %
    %   See README.md section 8 for the full reference.

    properties
        Recorder spincam.VideoRecorder
        Sync spincam.SyncController
        PreviewMaxHz (1,1) double {mustBeNonnegative} = 30
        StopTimeoutSeconds (1,1) double {mustBePositive} = 120
        %OVERWRITE Allow startRecording to replace existing output files.
        Overwrite (1,1) logical = false
        %RESETONDISCONNECT Restore free-run / embedding off / strobe pattern on disconnect.
        ResetOnDisconnect (1,1) logical = true
        %DATAROOT Root of sessionFolder(): <DataRoot>\<subject>\<session>.
        DataRoot (1,:) char = 'D:\videoData'
        %APPENDDATETIME Append _<recording start time> to every output file name.
        AppendDateTime (1,1) logical = true
        DateTimeFormat (1,:) char = 'yyyyMMdd_HHmmss'
        %DEFAULTFRAMERATE Frame rate (Hz) set on each camera when it connects; [] leaves it as is.
        DefaultFrameRate double {mustBeScalarOrEmpty, mustBePositive} = 100
        %DEFAULTCAMERANAMES Names given to cameras in ascending serial-number order.
        DefaultCameraNames cell = {'topview', 'sideview'}
    end

    properties (SetAccess = private)
        Backend char = ''
        Cameras = spincam.CameraDevice.empty(1, 0)
        State char = 'idle'
        LastRecording struct = struct()
        CurrentRecording struct = struct()
    end

    properties (Access = private)
        Impl = []
        EventFid = -1
        PreviewBeforeRecording logical = false
        RecordingStartedAt = []
        CurrentPaths = struct([])
        % Names given to cameras in this session; they survive disconnect/reconnect.
        KnownNames = struct('Serial', {}, 'Name', {})
    end

    methods
        function obj = CameraManager(opts)
            arguments
                opts.Backend (1,:) char {mustBeMember(opts.Backend, {'spinnaker', 'mock'})} = 'spinnaker'
                opts.FrameRate double {mustBeScalarOrEmpty, mustBePositive} = 100
                opts.NumCameras (1,1) double {mustBeInteger, mustBePositive} = 2
                opts.Resolution (1,2) double {mustBeInteger, mustBePositive} = [1024 1280]
                opts.GammaAvailable (1,1) logical = false
                opts.TtlHalfPeriodFrames (1,1) double {mustBeInteger, mustBePositive} = 30
                opts.DropEvery (1,1) double {mustBeInteger, mustBeNonnegative} = 0
                opts.IncompleteEvery (1,1) double {mustBeInteger, mustBeNonnegative} = 0
            end
            obj.Recorder = spincam.VideoRecorder();
            obj.Sync = spincam.SyncController();
            obj.Backend = opts.Backend;
            obj.DefaultFrameRate = opts.FrameRate;
            if strcmp(opts.Backend, 'mock')
                mockRate = opts.FrameRate;
                if isempty(mockRate)
                    mockRate = 60;
                end
                obj.Impl = spincam.internal.MockBackend('NumCameras', opts.NumCameras, ...
                    'FrameRate', mockRate, 'Resolution', opts.Resolution, ...
                    'GammaAvailable', opts.GammaAvailable, 'TtlHalfPeriodFrames', opts.TtlHalfPeriodFrames, ...
                    'DropEvery', opts.DropEvery, 'IncompleteEvery', opts.IncompleteEvery);
            else
                obj.Impl = spincam.internal.SpinnakerBackend();
            end
        end

        % ------------------------------------------------------------- connection
        function T = listCameras(obj)
            info = obj.Impl.listCameras();
            if isempty(info)
                T = table(cell(0, 1), cell(0, 1), cell(0, 1), cell(0, 1), cell(0, 1), false(0, 1), ...
                    'VariableNames', {'Serial', 'Name', 'Model', 'Firmware', 'Speed', 'Connected'});
                return
            end
            T = struct2table(info(:), 'AsArray', true);
            T.Connected = ismember(T.Serial, obj.serials());
            names = cell(height(T), 1);
            for k = 1:height(T)
                names{k} = obj.knownName(T.Serial{k});
            end
            T = addvars(T, names, 'After', 'Serial', 'NewVariableNames', 'Name');
        end

        function connect(obj, ids)
            %CONNECT Open cameras: all (default), serials (cellstr/string) or indices.
            %   Newly connected cameras get a name (DefaultCameraNames by serial order, or
            %   the name set earlier in this session) and DefaultFrameRate.
            arguments
                obj
                ids = []
            end
            if strcmp(obj.State, 'recording')
                error('spincam:manager:recording', 'Cannot connect cameras while recording.');
            end
            info = obj.Impl.listCameras();
            available = {info.Serial};
            if isempty(ids)
                wanted = available;
            elseif isnumeric(ids)
                if any(ids < 1 | ids > numel(available) | ids ~= round(ids))
                    error('spincam:manager:badIndex', 'Camera index out of range (1..%d).', numel(available));
                end
                wanted = available(ids);
            else
                wanted = cellstr(ids);
            end
            restart = strcmp(obj.State, 'preview');
            if restart
                obj.stopStreams();
            end
            for k = 1:numel(wanted)
                serial = wanted{k};
                if any(strcmp(obj.serials(), serial))
                    continue
                end
                if ~any(strcmp(available, serial))
                    error('spincam:manager:cameraNotFound', 'Camera %s is not attached (available: %s).', ...
                        serial, strjoin(available, ', '));
                end
                dev = obj.Impl.open(serial);
                dev.Name = obj.initialName(serial, available);
                obj.rememberName(serial, dev.Name);
                obj.Cameras(end + 1) = dev;
                obj.applyDefaultFrameRate(dev);
            end
            if isempty(obj.Cameras)
                warning('spincam:manager:noCameras', 'No cameras connected.');
            end
            if restart
                obj.startPreview();
            end
        end

        function disconnect(obj, ids)
            %DISCONNECT Close all cameras (default) or the given serials/names/indices.
            %   Disconnecting everything stops an active recording; disconnecting a
            %   subset is refused while recording.
            arguments
                obj
                ids = []
            end
            if isempty(ids)
                selected = true(1, numel(obj.Cameras));
            else
                if strcmp(obj.State, 'recording')
                    error('spincam:manager:recording', 'Cannot disconnect individual cameras while recording.');
                end
                targets = obj.select(ids);
                selected = ismember(obj.serials(), {targets.Serial});
            end
            if strcmp(obj.State, 'recording')
                obj.stopRecording();
            end
            restart = strcmp(obj.State, 'preview') && ~all(selected);
            obj.stopStreams();
            for k = find(selected, 1, 'last'):-1:1
                if ~selected(k)
                    continue
                end
                dev = obj.Cameras(k);
                if obj.ResetOnDisconnect
                    try
                        spincam.SyncController.reset(dev);
                    catch me
                        warning('spincam:manager:resetFailed', 'Resetting camera %s: %s', dev.Serial, me.message);
                    end
                end
                try
                    obj.Impl.close(dev);
                catch me
                    warning('spincam:manager:closeFailed', 'Closing camera %s: %s', dev.Serial, me.message);
                end
            end
            obj.Cameras = obj.Cameras(~selected);
            obj.State = 'idle';
            if restart && ~isempty(obj.Cameras)
                obj.startPreview();
            end
        end

        function dev = camera(obj, id)
            %CAMERA Connected camera by index, serial number or camera name.
            if isnumeric(id)
                if id < 1 || id > numel(obj.Cameras)
                    error('spincam:manager:badIndex', 'Camera index %d out of range (1..%d).', id, numel(obj.Cameras));
                end
                dev = obj.Cameras(id);
                return
            end
            match = strcmp(obj.serials(), char(id));
            if ~any(match)
                match = strcmpi({obj.Cameras.Name}, char(id));
            end
            if ~any(match)
                error('spincam:manager:notConnected', 'Camera %s is not connected.', char(id));
            end
            dev = obj.Cameras(find(match, 1));
        end

        function setCameraName(obj, id, name)
            %SETCAMERANAME Name used as the file-name prefix for this camera (e.g. 'topview').
            %   Letters, digits, '-' and '_' are kept; other characters become '_'.
            arguments
                obj
                id
                name {mustBeTextScalar}
            end
            if strcmp(obj.State, 'recording')
                error('spincam:manager:recording', 'Cannot rename cameras while recording.');
            end
            dev = obj.camera(id);
            clean = spincam.CameraManager.cleanName(name);
            if isempty(clean)
                error('spincam:manager:badCameraName', 'Camera name must not be empty.');
            end
            others = obj.Cameras(~strcmp(obj.serials(), dev.Serial));
            if any(strcmpi({others.Name}, clean))
                error('spincam:manager:duplicateCameraName', ...
                    'Another connected camera is already named "%s".', clean);
            end
            dev.Name = clean;
            obj.rememberName(dev.Serial, clean);
        end

        % ------------------------------------------------------------- properties
        function actual = setProperty(obj, name, value, ids)
            arguments
                obj
                name {mustBeTextScalar}
                value
                ids = []
            end
            devices = obj.select(ids);
            def = spincam.internal.PropertyRegistry.lookup(name);
            restart = false;
            if ~isempty(def) && def.RequiresStopped
                if strcmp(obj.State, 'recording')
                    error('spincam:manager:recording', '%s cannot be changed while recording.', def.Name);
                elseif strcmp(obj.State, 'preview')
                    obj.stopStreams();
                    restart = true;
                end
            end
            actual = cell(1, numel(devices));
            try
                for k = 1:numel(devices)
                    actual{k} = devices(k).set(name, value);
                end
            catch me
                if restart
                    obj.startStreams();
                end
                rethrow(me);
            end
            if restart
                obj.startStreams();
            end
            actual = simplify(actual);
        end

        function v = getProperty(obj, name, ids)
            arguments
                obj
                name {mustBeTextScalar}
                ids = []
            end
            devices = obj.select(ids);
            v = cell(1, numel(devices));
            for k = 1:numel(devices)
                v{k} = devices(k).get(name);
            end
            v = simplify(v);
        end

        % ------------------------------------------------------------------- crop
        function actual = setRoi(obj, roi, ids, opts)
            %SETROI Crop cameras to ROI = [x y width height] in sensor pixels.
            %   cm.setRoi([0 0 1024 900], [], 'Center', true)  centred crop on all cameras
            %   cm.setRoi([128 60 1024 900], {'topview'})       one camera
            %   A smaller crop encodes faster and allows higher frame rates. Preview restarts
            %   automatically; refused while recording. Returns one [x y w h] row per camera.
            arguments
                obj
                roi (1,4) double {mustBeNonnegative}
                ids = []
                opts.Center (1,1) logical = false
            end
            actual = obj.forEachStopped(ids, 'crop', @(dev) dev.setRoi(roi, 'Center', opts.Center));
        end

        function actual = resetRoi(obj, ids)
            %RESETROI Full frame on all (default) or the given cameras.
            arguments
                obj
                ids = []
            end
            actual = obj.forEachStopped(ids, 'crop', @(dev) dev.resetRoi());
        end

        function roi = getRoi(obj, ids)
            %GETROI Current crop, one [x y width height] row per camera.
            arguments
                obj
                ids = []
            end
            devices = obj.select(ids);
            roi = zeros(numel(devices), 4);
            for k = 1:numel(devices)
                roi(k, :) = devices(k).getRoi();
            end
        end

        % ------------------------------------------------------------------- sync
        function configureSync(obj, mode, varargin)
            %CONFIGURESYNC Replace Sync with SyncController(mode, ...) and apply it.
            if strcmp(obj.State, 'recording')
                error('spincam:manager:recording', 'Cannot change sync settings while recording.');
            end
            obj.Sync = spincam.SyncController(mode, varargin{:});
            if ~isempty(obj.Cameras)
                obj.applySync();
            end
        end

        function applySync(obj)
            if strcmp(obj.State, 'recording')
                error('spincam:manager:recording', 'Cannot change sync settings while recording.');
            end
            restart = strcmp(obj.State, 'preview');
            if restart
                obj.stopStreams();
            end
            for k = 1:numel(obj.Cameras)
                obj.Sync.apply(obj.Cameras(k));
            end
            if restart
                obj.startStreams();
            end
        end

        % -------------------------------------------------------------- streaming
        function startPreview(obj)
            obj.requireConnected();
            if ~strcmp(obj.State, 'idle')
                return
            end
            obj.applySync();
            obj.warnIfBandwidthHigh();
            obj.startStreams();
            obj.State = 'preview';
        end

        function stopPreview(obj)
            if strcmp(obj.State, 'recording')
                error('spincam:manager:recording', 'Stop recording before stopping preview.');
            end
            obj.stopStreams();
            obj.State = 'idle';
        end

        function folder = sessionFolder(obj, subject, session)
            %SESSIONFOLDER <DataRoot>\<subject>\<session> (session optional). Not created here.
            arguments
                obj
                subject {mustBeTextScalar}
                session {mustBeTextScalar} = ''
            end
            subject = strtrim(char(subject));
            if isempty(subject)
                error('spincam:manager:noSubject', 'Subject name is empty.');
            end
            parts = {spincam.internal.toWindowsPath(obj.DataRoot), spincam.internal.sanitizeFileName(subject)};
            session = strtrim(char(session));
            if ~isempty(session)
                parts{end + 1} = spincam.internal.sanitizeFileName(session);
            end
            folder = fullfile(parts{:});
        end

        function names = plannedFileNames(obj, fileName, when)
            %PLANNEDFILENAMES File stems startRecording would use: <camera>_<fileName>_<datetime>.
            %   names.Cameras{k} is the stem for Cameras(k); names.Shared prefixes the
            %   _events.csv and _session.json files.
            arguments
                obj
                fileName {mustBeTextScalar} = ''
                when (1,1) datetime = datetime('now')
            end
            parts = {};
            clean = spincam.CameraManager.cleanName(fileName);
            if ~isempty(clean)
                parts{end + 1} = clean;
            end
            if obj.AppendDateTime
                parts{end + 1} = char(datetime(when, 'Format', obj.DateTimeFormat));
            end
            tag = strjoin(parts, '_');
            names.Shared = tag;
            if isempty(tag)
                names.Shared = 'recording';
            end
            names.Cameras = cell(1, numel(obj.Cameras));
            for k = 1:numel(obj.Cameras)
                label = obj.fileLabel(obj.Cameras(k));
                if isempty(tag)
                    names.Cameras{k} = label;
                else
                    names.Cameras{k} = [label '_' tag];
                end
            end
        end

        function plan = startRecording(obj, folder, fileName)
            %STARTRECORDING Record all connected cameras into FOLDER.
            %   Each camera writes <folder>\<name>_<fileName>_<datetime>.avi (or .mp4/.raw)
            %   and a .csv with the same name; see plannedFileNames and AppendDateTime.
            arguments
                obj
                folder {mustBeTextScalar}
                fileName {mustBeTextScalar} = ''
            end
            obj.requireConnected();
            if strcmp(obj.State, 'recording')
                error('spincam:manager:alreadyRecording', 'Already recording.');
            end
            devices = obj.Cameras;
            labels = arrayfun(@(d) obj.fileLabel(d), devices, 'UniformOutput', false);
            if numel(unique(lower(labels))) < numel(labels)
                error('spincam:manager:duplicateCameraName', ...
                    'Camera names must be unique to keep file names apart (%s).', strjoin(labels, ', '));
            end
            folder = spincam.internal.toWindowsPath(folder);
            if ~isfolder(folder)
                [ok, msg] = mkdir(folder);
                if ~ok
                    error('spincam:manager:folder', 'Cannot create output folder %s: %s', folder, msg);
                end
            end
            startedAt = datetime('now');
            names = obj.plannedFileNames(fileName, startedAt);
            paths = repmat(struct('Stem', '', 'VideoFile', '', 'SegmentFile', '', 'CsvFile', ''), 1, numel(devices));
            for k = 1:numel(devices)
                paths(k) = obj.Recorder.plannedPaths(folder, names.Cameras{k});
            end
            eventsFile = fullfile(folder, [names.Shared '_events.csv']);
            sessionFile = fullfile(folder, [names.Shared '_session.json']);
            if ~obj.Overwrite
                candidates = [{paths.CsvFile}, {paths.VideoFile}, {paths.SegmentFile}, {eventsFile, sessionFile}];
                candidates = candidates(~cellfun(@isempty, candidates));
                existing = candidates(isfile(candidates));
                if ~isempty(existing)
                    error('spincam:manager:filesExist', ...
                        'Output files already exist (set Overwrite = true to replace): %s', strjoin(existing, ', '));
                end
            end

            obj.PreviewBeforeRecording = strcmp(obj.State, 'preview');
            if ~obj.PreviewBeforeRecording
                obj.startPreview();
            end
            gate = obj.Sync.recordGate();
            options = cell(1, numel(devices));
            started = false(1, numel(devices));
            try
                for k = 1:numel(devices)
                    options{k} = obj.Recorder.buildOptions(devices(k), paths(k), gate);
                end
                obj.EventFid = fopen(eventsFile, 'w');
                if obj.EventFid < 0
                    error('spincam:manager:eventsFile', 'Cannot create %s.', eventsFile);
                end
                fprintf(obj.EventFid, 'HostTime_s,HostTimestamp_datetime,Event,Value\n');
                obj.Recorder.begin(devices, options);
                for k = 1:numel(devices)
                    devices(k).startRecording(options{k});
                    started(k) = true;
                end
            catch me
                for k = find(started)
                    devices(k).beginStopRecording();
                end
                for k = find(started)
                    devices(k).endStopRecording(obj.StopTimeoutSeconds);
                end
                obj.Recorder.abort();
                obj.closeEvents();
                if ~obj.PreviewBeforeRecording
                    obj.stopStreams();
                    obj.State = 'idle';
                end
                rethrow(me);
            end

            obj.State = 'recording';
            obj.RecordingStartedAt = startedAt;
            obj.CurrentPaths = paths;
            plan = struct('Folder', folder, 'BaseName', names.Shared, 'FileName', char(fileName), ...
                'StartTime', char(datetime(startedAt, 'Format', 'yyyy-MM-dd''T''HH:mm:ss')), ...
                'Format', obj.Recorder.Format, 'Gate', gate, 'EventsFile', eventsFile, 'SessionFile', sessionFile, ...
                'Cameras', struct('Serial', {devices.Serial}, 'Name', labels, 'VideoFile', {paths.VideoFile}, ...
                'CsvFile', {paths.CsvFile}));
            obj.CurrentRecording = plan;
            obj.writeSession(plan, struct());
            obj.logEvent('RecordingStart', gate);
        end

        function summary = stopRecording(obj)
            %STOPRECORDING Finalize files on all cameras; returns per-camera results.
            if ~strcmp(obj.State, 'recording')
                warning('spincam:manager:notRecording', 'Not recording.');
                summary = obj.LastRecording;
                return
            end
            obj.logEvent('RecordingStop', '');
            devices = obj.Cameras;
            for k = 1:numel(devices)
                devices(k).beginStopRecording();
            end
            results = cell(1, numel(devices));
            for k = 1:numel(devices)
                results{k} = devices(k).endStopRecording(obj.StopTimeoutSeconds);
            end
            matlabFiles = obj.Recorder.finish();
            obj.closeEvents();

            plan = obj.CurrentRecording;
            cams = repmat(struct('Serial', '', 'Name', '', 'VideoFiles', {{}}, 'CsvFile', '', 'FramesLogged', 0, ...
                'FramesWritten', 0, 'WriterDrops', 0, 'FramesMissed', 0, 'FramesIncomplete', 0, ...
                'QueuePeak', 0, 'GateOpened', false, 'Error', ''), 1, numel(devices));
            for k = 1:numel(devices)
                r = results{k};
                cams(k).Serial = devices(k).Serial;
                cams(k).Name = plan.Cameras(k).Name;
                cams(k).CsvFile = plan.Cameras(k).CsvFile;
                if obj.Recorder.isMatlab()
                    cams(k).VideoFiles = matlabFiles(k);
                else
                    cams(k).VideoFiles = obj.Recorder.finalizeFiles(asCellstr(fieldOr(r, 'files', {})), ...
                        obj.CurrentPaths(k));
                end
                cams(k).FramesLogged = fieldOr(r, 'framesLogged', 0);
                cams(k).FramesWritten = fieldOr(r, 'framesWritten', 0);
                cams(k).WriterDrops = fieldOr(r, 'writerDrops', 0);
                cams(k).FramesMissed = fieldOr(r, 'framesMissed', 0);
                cams(k).FramesIncomplete = fieldOr(r, 'framesIncomplete', 0);
                cams(k).QueuePeak = fieldOr(r, 'queuePeak', 0);
                cams(k).GateOpened = logical(fieldOr(r, 'gateOpen', false));
                cams(k).Error = char(fieldOr(r, 'error', ''));
            end
            summary = rmfield(plan, 'Cameras');
            summary.Cameras = cams;
            summary.Duration_s = seconds(datetime('now') - obj.RecordingStartedAt);
            obj.LastRecording = summary;
            obj.CurrentRecording = struct();
            obj.CurrentPaths = struct([]);
            obj.writeSession(plan, summary);

            if obj.PreviewBeforeRecording
                obj.State = 'preview';
            else
                obj.stopStreams();
                obj.State = 'idle';
            end
            failed = cams(~cellfun(@isempty, {cams.Error}));
            if ~isempty(failed)
                warning('spincam:manager:recordingErrors', 'Recording errors: %s', ...
                    strjoin(arrayfun(@(c) sprintf('%s: %s', c.Serial, c.Error), failed, 'UniformOutput', false), ' | '));
            end
        end

        function [frames, meta] = getLatestFrames(obj, ids)
            %GETLATESTFRAMES Preview frames (cell of H-by-W uint8) and metadata.
            arguments
                obj
                ids = []
            end
            devices = obj.select(ids);
            frames = cell(1, numel(devices));
            metaCells = cell(1, numel(devices));
            for k = 1:numel(devices)
                [frames{k}, metaCells{k}] = devices(k).latestFrame();
            end
            meta = [metaCells{:}];
        end

        function T = getStats(obj)
            %GETSTATS One row per connected camera.
            n = numel(obj.Cameras);
            Serial = cell(n, 1); Name = cell(n, 1); Running = false(n, 1); Recording = false(n, 1);
            Armed = false(n, 1); FPS = nan(n, 1); FramesReceived = zeros(n, 1); FramesMissed = zeros(n, 1);
            FramesIncomplete = zeros(n, 1); GrabTimeouts = zeros(n, 1); QueueDepth = zeros(n, 1);
            FramesWritten = zeros(n, 1); WriterDrops = zeros(n, 1); LastTTL = nan(n, 1);
            LastFrameId = nan(n, 1); Faulted = false(n, 1); LastError = cell(n, 1);
            for k = 1:n
                dev = obj.Cameras(k);
                Serial{k} = dev.Serial;
                Name{k} = dev.Name;
                LastError{k} = '';
                if isempty(dev.Stream)
                    continue
                end
                s = dev.stats();
                Running(k) = s.running;
                Recording(k) = s.recording;
                Armed(k) = s.armed;
                FPS(k) = double(fieldOr(s, 'fps', NaN));
                FramesReceived(k) = s.framesReceived;
                FramesMissed(k) = s.framesMissed;
                FramesIncomplete(k) = s.framesIncomplete;
                GrabTimeouts(k) = s.grabTimeouts;
                QueueDepth(k) = s.queueDepth;
                LastTTL(k) = s.lastTtl;
                LastFrameId(k) = s.lastFrameId;
                Faulted(k) = s.faulted;
                LastError{k} = s.lastError;
                if isstruct(s.lastRecording)
                    FramesWritten(k) = s.lastRecording.framesWritten;
                    WriterDrops(k) = s.lastRecording.writerDrops;
                end
            end
            T = table(Serial, Name, Running, Recording, Armed, FPS, FramesReceived, FramesMissed, ...
                FramesIncomplete, GrabTimeouts, QueueDepth, FramesWritten, WriterDrops, LastTTL, ...
                LastFrameId, Faulted, LastError);
        end

        % ----------------------------------------------------------------- events
        function logEvent(obj, name, value)
            %LOGEVENT Append a row to <base>_events.csv on the engine host clock.
            arguments
                obj
                name {mustBeTextScalar}
                value = ''
            end
            if obj.EventFid < 0
                warning('spincam:manager:noEventLog', 'logEvent("%s") ignored: not recording.', char(name));
                return
            end
            fprintf(obj.EventFid, '%.6f,%s,%s,%s\n', obj.hostTime(), hostIso(), csvField(char(name)), ...
                csvField(valueText(value)));
        end

        function t = hostTime(~)
            %HOSTTIME Seconds on the engine clock (same clock as the CSV HostTime_s).
            t = NaN;
            if spincam.internal.NativeEngine.isLoaded()
                t = double(SpinCam.HostClock.NowSeconds());
            end
        end

        function delete(obj)
            if strcmp(obj.State, 'recording')
                try
                    obj.stopRecording();
                catch me
                    warning('spincam:manager:deleteFailed', 'Stopping recording: %s', me.message);
                end
            end
            try
                obj.disconnect();
            catch me
                warning('spincam:manager:deleteFailed', 'Disconnecting: %s', me.message);
            end
            try
                if ~isempty(obj.Impl) && isvalid(obj.Impl)
                    obj.Impl.shutdown();
                end
            catch me
                warning('spincam:manager:deleteFailed', 'Backend shutdown: %s', me.message);
            end
            obj.closeEvents();
        end
    end

    methods (Static)
        function name = cleanName(name)
            %CLEANNAME Keep letters, digits, '-' and '_'; other runs of characters become '_'.
            name = regexprep(strtrim(char(name)), '[^A-Za-z0-9_\-]+', '_');
            name = regexprep(name, '^_+|_+$', '');
        end
    end

    methods (Access = private)
        function s = serials(obj)
            s = {obj.Cameras.Serial};
        end

        function devices = select(obj, ids)
            obj.requireConnected();
            if isempty(ids)
                devices = obj.Cameras;
                return
            end
            if ~isnumeric(ids)
                ids = cellstr(ids);
            end
            devices = spincam.CameraDevice.empty(1, 0);
            for k = 1:numel(ids)
                if iscell(ids)
                    devices(end + 1) = obj.camera(ids{k}); %#ok<AGROW>
                else
                    devices(end + 1) = obj.camera(ids(k)); %#ok<AGROW>
                end
            end
        end

        function out = forEachStopped(obj, ids, what, fn)
            % Apply FN (returning a row) to cameras with streams stopped, restarting preview.
            devices = obj.select(ids);
            if strcmp(obj.State, 'recording')
                error('spincam:manager:recording', 'Cannot change the %s while recording.', what);
            end
            restart = strcmp(obj.State, 'preview');
            if restart
                obj.stopStreams();
            end
            out = zeros(numel(devices), 4);
            try
                for k = 1:numel(devices)
                    out(k, :) = fn(devices(k));
                end
            catch me
                if restart
                    obj.startStreams();
                end
                rethrow(me);
            end
            if restart
                obj.warnIfBandwidthHigh();
                obj.startStreams();
            end
        end

        function requireConnected(obj)
            if isempty(obj.Cameras)
                error('spincam:manager:notConnected', 'No cameras connected; call connect() first.');
            end
        end

        function name = knownName(obj, serial)
            name = '';
            k = find(strcmp({obj.KnownNames.Serial}, serial), 1);
            if ~isempty(k)
                name = obj.KnownNames(k).Name;
            end
        end

        function rememberName(obj, serial, name)
            k = find(strcmp({obj.KnownNames.Serial}, serial), 1);
            if isempty(k)
                k = numel(obj.KnownNames) + 1;
            end
            obj.KnownNames(k) = struct('Serial', serial, 'Name', name);
        end

        function name = initialName(obj, serial, available)
            % Remembered name first, then DefaultCameraNames by serial rank, so the same
            % physical camera gets the same default however cameras are connected.
            taken = {obj.Cameras.Name};
            name = obj.knownName(serial);
            if ~isempty(name) && ~any(strcmpi(taken, name))
                return
            end
            rank = find(strcmp(sort(available), serial), 1);
            name = ['cam' serial];
            if ~isempty(rank) && rank <= numel(obj.DefaultCameraNames)
                candidate = spincam.CameraManager.cleanName(obj.DefaultCameraNames{rank});
                if ~isempty(candidate) && ~any(strcmpi(taken, candidate))
                    name = candidate;
                end
            end
        end

        function label = fileLabel(~, dev)
            label = spincam.CameraManager.cleanName(dev.Name);
            if isempty(label)
                label = ['cam' dev.Serial];
            end
        end

        function applyDefaultFrameRate(obj, dev)
            rate = obj.DefaultFrameRate;
            if isempty(rate)
                return
            end
            try
                nm = dev.NodeMap;
                % With manual exposure the CM3 caps the frame rate by the exposure time, so
                % shorten a too-long exposure to fit the frame period first.
                if nm.has('ExposureAuto') && nm.isReadable('ExposureAuto') && strcmp(nm.get('ExposureAuto'), 'Off') ...
                        && nm.isReadable('ExposureTime')
                    limit = floor(0.99e6 / rate);
                    if nm.get('ExposureTime') > limit
                        dev.set('ExposureTime', limit);
                    end
                end
                dev.set('FrameRate', rate);
            catch me
                warning('spincam:manager:defaultFrameRate', 'Could not set %g fps on camera %s: %s', ...
                    rate, dev.Serial, me.message);
            end
        end

        function startStreams(obj)
            started = false(1, numel(obj.Cameras));
            try
                for k = 1:numel(obj.Cameras)
                    dev = obj.Cameras(k);
                    dev.ScrubEmbeddedPixels = obj.Recorder.ScrubEmbeddedPixels;
                    dev.startStream(obj.PreviewMaxHz);
                    started(k) = true;
                end
            catch me
                for k = find(started)
                    obj.Cameras(k).stopStream();
                end
                rethrow(me);
            end
        end

        function stopStreams(obj)
            for k = 1:numel(obj.Cameras)
                try
                    obj.Cameras(k).stopStream();
                catch me
                    warning('spincam:manager:stopFailed', 'Stopping camera %s: %s', obj.Cameras(k).Serial, me.message);
                end
            end
        end

        function warnIfBandwidthHigh(obj)
            % Two CM3-U3-13Y3M sharing one USB 3.0 controller lost frames on the camera side
            % at ~390 MB/s combined (2 x 150 fps full frame) and none at ~310 MB/s (2 x 120 fps).
            if ~strcmp(obj.Backend, 'spinnaker') || numel(obj.Cameras) < 2
                return
            end
            total = 0;
            for k = 1:numel(obj.Cameras)
                dev = obj.Cameras(k);
                try
                    if ~strcmp(dev.get('TriggerMode'), 'On')
                        total = total + dev.get('Width') * dev.get('Height') * dev.get('FrameRate');
                    end
                catch
                end
            end
            if total > 340e6
                warning('spincam:manager:usbBandwidth', ['Combined camera data rate is %.0f MB/s. Cameras sharing ' ...
                    'one USB 3.0 host controller lost frames at ~390 MB/s in testing (none at ~310 MB/s). ' ...
                    'Use separate host controllers, or lower FrameRate/ROI; FramesMissedBefore reports any loss.'], ...
                    total / 1e6);
            end
        end

        function closeEvents(obj)
            if obj.EventFid >= 0
                fclose(obj.EventFid);
            end
            obj.EventFid = -1;
        end

        function writeSession(obj, plan, summary)
            s = struct();
            s.SpincamVersion = spincam.version();
            s.MatlabVersion = version();
            s.Backend = obj.Backend;
            s.Written = char(datetime('now', 'TimeZone', 'local', 'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSxxx'));
            s.EngineVersion = '';
            s.HostClockAnchor = '';
            if spincam.internal.NativeEngine.isLoaded()
                s.EngineVersion = char(SpinCam.Engine.Version);
                s.HostClockAnchor = char(SpinCam.HostClock.AnchorIso);
            end
            s.Recording = plan;
            s.Sync = publicProperties(obj.Sync);
            s.Recorder = obj.Recorder.toStruct();
            cams = cell(1, numel(obj.Cameras));
            for k = 1:numel(obj.Cameras)
                dev = obj.Cameras(k);
                settings = struct();
                try
                    settings = dev.getSettings();
                catch
                end
                cams{k} = struct('Serial', dev.Serial, 'Name', dev.Name, 'Model', dev.Model, ...
                    'Firmware', dev.Firmware, 'SyncPlan', dev.SyncPlan, 'Settings', settings);
            end
            s.Cameras = cams;
            if ~isempty(fieldnames(summary))
                s.Summary = summary;
            end
            fid = fopen(plan.SessionFile, 'w');
            if fid < 0
                warning('spincam:manager:sessionFile', 'Cannot write %s.', plan.SessionFile);
                return
            end
            closer = onCleanup(@() fclose(fid));
            fwrite(fid, jsonencode(s, 'PrettyPrint', true), 'char');
        end
    end
end

function out = simplify(values)
if all(cellfun(@(v) (isnumeric(v) || islogical(v)) && isscalar(v), values))
    out = cellfun(@double, values);
else
    out = values;
end
end

function v = fieldOr(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = default;
end
end

function c = asCellstr(v)
if isempty(v)
    c = {};
elseif ischar(v)
    c = {v};
else
    c = reshape(cellstr(v), 1, []);
end
end

function s = publicProperties(h)
s = struct();
mc = metaclass(h);
for p = mc.PropertyList'
    if strcmp(p.GetAccess, 'public') && strcmp(p.SetAccess, 'public') && ~p.Constant && ~p.Dependent && ~p.Hidden
        s.(p.Name) = h.(p.Name);
    end
end
end

function t = hostIso()
if spincam.internal.NativeEngine.isLoaded()
    t = char(SpinCam.HostClock.NowIso());
else
    t = char(datetime('now', 'TimeZone', 'local', 'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSSSSxxx'));
end
end

function t = valueText(value)
if ischar(value) || isstring(value)
    t = char(value);
elseif (isnumeric(value) || islogical(value)) && isscalar(value)
    t = sprintf('%.15g', double(value));
else
    t = jsonencode(value);
end
end

function f = csvField(text)
if any(text == ',' | text == '"' | text == newline | text == char(13))
    f = ['"' strrep(text, '"', '""') '"'];
else
    f = text;
end
end
