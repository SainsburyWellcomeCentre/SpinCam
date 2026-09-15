classdef VideoRecorder < handle
    %VIDEORECORDER Video and CSV output settings for spincam recordings.
    %   Formats:
    %     'avi-mjpeg'    SpinVideo MJPEG AVI, encoded on the engine's writer thread
    %     'avi-raw'      SpinVideo uncompressed AVI
    %     'mp4-h264'     SpinVideo H.264 MP4
    %     'raw'          lossless 8-bit frames (.raw + .raw.json) at disk speed; read with
    %                    spincam.io.RawVideoReader, convert with spincam.io.rawToAvi
    %     'matlab-avi'   MATLAB VideoWriter 'Grayscale AVI' (drained by a MATLAB timer)
    %     'matlab-mjpeg' MATLAB VideoWriter 'Motion JPEG AVI'
    %     'none'         CSV metadata only
    %   The matlab-* formats need MATLAB to be idle to drain frames; do not use
    %   them while MATLAB is blocked (e.g. Bpod RunStateMachine).

    properties
        Format (1,:) char = 'avi-mjpeg'
        Quality (1,1) double {mustBeInteger, mustBeInRange(Quality, 1, 100)} = 75
        H264BitrateMbps (1,1) double {mustBePositive} = 8
        H264Crf (1,1) double {mustBeInteger, mustBeInRange(H264Crf, 0, 51)} = 23
        %FRAMERATE Container frame rate; [] uses the camera's AcquisitionFrameRate.
        FrameRate double {mustBeScalarOrEmpty} = []
        MaxFileSizeMB (1,1) double {mustBeInteger, mustBeNonnegative} = 0
        %QUEUESECONDS Writer queue depth in seconds of video (capped by MaxQueueMB).
        QueueSeconds (1,1) double {mustBePositive} = 10
        MaxQueueMB (1,1) double {mustBePositive} = 2048
        CsvExtended (1,1) logical = true
        ScrubEmbeddedPixels (1,1) logical = true
        DrainPeriod (1,1) double {mustBePositive} = 0.02
    end

    properties (Constant)
        Formats = {'avi-mjpeg', 'avi-raw', 'mp4-h264', 'raw', 'matlab-avi', 'matlab-mjpeg', 'none'}
        % Encoder capacity (frames/s per camera at 1280x1024; scaled by pixel count for crops).
        % avi_mjpeg and mp4_h264: real camera frames, 2 cameras at 120 fps, dark scene with 18 dB
        % gain (2026-09-15); synthetic frames overstate both (116 / 121). Others: synthetic frames
        % from spincam.tools.benchmarkWriters. Development rig: i7-14700K, NVMe.
        MeasuredCapacity = struct('avi_mjpeg', 104, 'avi_raw', 110, 'mp4_h264', 70, 'matlab_mjpeg', 85)
    end

    properties (SetAccess = private)
        Writers = {}
        Devices = {}
        Errors = {}
    end

    properties (Access = private)
        DrainTimer = []
    end

    methods
        function set.Format(obj, value)
            value = lower(char(value));
            if ~any(strcmp(spincam.VideoRecorder.Formats, value))
                error('spincam:recorder:badFormat', 'Format must be one of: %s.', ...
                    strjoin(spincam.VideoRecorder.Formats, ', '));
            end
            obj.Format = value;
        end

        function tf = isNative(obj)
            %ISNATIVE Written on the engine's threads (safe while MATLAB is blocked).
            tf = obj.isSpinVideo() || strcmp(obj.Format, 'raw');
        end

        function tf = isSpinVideo(obj)
            tf = any(strcmp(obj.Format, {'avi-mjpeg', 'avi-raw', 'mp4-h264'}));
        end

        function checkThroughput(obj, fps, width, height, serial)
            %CHECKTHROUGHPUT Warn when the encoder is unlikely to keep up with FPS.
            key = strrep(obj.Format, '-', '_');
            if ~isfield(obj.MeasuredCapacity, key)
                return
            end
            capacity = obj.MeasuredCapacity.(key) * (1280 * 1024) / max(1, width * height);
            if fps > capacity
                warning('spincam:recorder:encoderMayNotKeepUp', ...
                    ['Camera %s at %.0f fps may exceed %s encoding speed (~%.0f fps measured at this frame ' ...
                    'size); frames are flagged as writer drops once the %g s queue fills. Lower the frame ' ...
                    'rate, crop the image (setRoi), or use Format ''raw''.'], serial, fps, obj.Format, capacity, ...
                    obj.QueueSeconds);
            end
        end

        function tf = isMatlab(obj)
            tf = startsWith(obj.Format, 'matlab-');
        end

        function ext = extension(obj)
            switch obj.Format
                case 'none'
                    ext = '';
                case 'mp4-h264'
                    ext = '.mp4';
                case 'raw'
                    ext = '.raw';
                otherwise
                    ext = '.avi';
            end
        end

        function p = plannedPaths(obj, folder, stem)
            %PLANNEDPATHS File names for one camera: <folder>\<stem>.avi|.mp4|.raw and <stem>.csv.
            %   SegmentFile is the name SpinVideo writes while recording (<stem>-0000.avi);
            %   finalizeFiles renames it to VideoFile when the recording is closed.
            stemPath = fullfile(folder, stem);
            videoFile = '';
            segmentFile = '';
            if ~strcmp(obj.Format, 'none')
                videoFile = [stemPath obj.extension()];
            end
            if obj.isSpinVideo()
                segmentFile = [stemPath '-0000' obj.extension()];
            end
            p = struct('Stem', stemPath, 'VideoFile', videoFile, 'SegmentFile', segmentFile, ...
                'CsvFile', [stemPath '.csv']);
        end

        function files = finalizeFiles(obj, files, paths)
            %FINALIZEFILES Rename a single SpinVideo segment <stem>-0000.ext to <stem>.ext,
            %   so video and CSV share one name. Split recordings (MaxFileSizeMB > 0) keep
            %   their numbered segments.
            files = reshape(cellstr(files), 1, []);
            if ~obj.isSpinVideo() || obj.MaxFileSizeMB > 0 || numel(files) ~= 1 || ...
                    ~strcmpi(files{1}, paths.SegmentFile)
                return
            end
            [ok, msg] = movefile(paths.SegmentFile, paths.VideoFile);
            if ok
                files = {paths.VideoFile};
            else
                warning('spincam:recorder:renameFailed', 'Could not rename %s to %s: %s', ...
                    paths.SegmentFile, paths.VideoFile, msg);
            end
        end

        function options = buildOptions(obj, device, paths, gate)
            %BUILDOPTIONS SpinCam.RecordingOptions for one camera (PATHS from plannedPaths).
            arguments
                obj
                device
                paths (1,1) struct
                gate (1,:) char = 'none'
            end
            p = paths;
            if obj.isSpinVideo() && ~spincam.internal.NativeEngine.hasSpinVideo()
                error('spincam:recorder:noSpinVideo', ['Format %s needs SpinVideoNET, which was not found in the ' ...
                    'Spinnaker installation. Use ''raw'', ''matlab-avi'' or ''matlab-mjpeg''.'], obj.Format);
            end
            fps = obj.resolveFrameRate(device);
            [width, height] = spincam.VideoRecorder.frameSize(device);
            obj.checkThroughput(fps, width, height, device.Serial);
            frameMB = width * height / 2^20;
            capacity = max(10, min(round(obj.QueueSeconds * fps), floor(obj.MaxQueueMB / frameMB)));
            options = SpinCam.RecordingOptions();
            options.CameraId = device.Serial;
            options.VideoPath = p.Stem;
            options.CsvPath = p.CsvFile;
            options.Format = obj.netFormat();
            options.FrameRate = fps;
            options.MjpgQuality = int32(obj.Quality);
            options.H264BitrateBps = int32(round(obj.H264BitrateMbps * 1e6));
            options.H264Crf = int32(obj.H264Crf);
            options.MaxFileSizeMB = int32(obj.MaxFileSizeMB);
            options.QueueCapacityFrames = int32(capacity);
            options.ExportCapacityFrames = int32(capacity);
            options.CsvExtended = obj.CsvExtended;
            if strcmp(gate, 'firstRisingEdge')
                options.Gate = SpinCam.RecordGate.FirstRisingEdge;
            else
                options.Gate = SpinCam.RecordGate.None;
            end
        end

        function fps = resolveFrameRate(obj, device)
            if ~isempty(obj.FrameRate)
                fps = obj.FrameRate;
                return
            end
            fps = NaN;
            nm = device.NodeMap;
            try
                triggered = nm.has('TriggerMode') && strcmp(nm.get('TriggerMode'), 'On');
                if ~triggered && nm.has('AcquisitionFrameRate') && nm.isReadable('AcquisitionFrameRate')
                    fps = nm.get('AcquisitionFrameRate');
                end
            catch
            end
            if ~(fps > 0)
                fps = 30;
                warning('spincam:recorder:frameRateUnknown', ...
                    'Frame rate of camera %s is unknown (triggered?); video container uses 30 fps. Set Recorder.FrameRate.', ...
                    device.Serial);
            end
        end

        function begin(obj, devices, options)
            %BEGIN Open MATLAB VideoWriters and start draining (matlab-* formats only).
            obj.abort();
            obj.Errors = {};
            if ~obj.isMatlab()
                return
            end
            if strcmp(obj.Format, 'matlab-mjpeg')
                profile = 'Motion JPEG AVI';
            else
                profile = 'Grayscale AVI';
            end
            try
                for k = 1:numel(devices)
                    writer = VideoWriter([char(options{k}.VideoPath) '.avi'], profile);
                    writer.FrameRate = options{k}.FrameRate;
                    if strcmp(profile, 'Motion JPEG AVI')
                        writer.Quality = obj.Quality;
                    end
                    open(writer);
                    obj.Writers{k} = writer;
                    obj.Devices{k} = devices(k);
                end
            catch me
                obj.abort();
                rethrow(me);
            end
            obj.DrainTimer = timer('Name', 'spincam-video-drain', 'ExecutionMode', 'fixedSpacing', ...
                'Period', obj.DrainPeriod, 'BusyMode', 'drop', 'TimerFcn', @(~, ~) obj.drain(0.05));
            start(obj.DrainTimer);
        end

        function n = drain(obj, budgetSeconds)
            %DRAIN Write queued frames to MATLAB VideoWriters for up to BUDGETSECONDS.
            n = 0;
            t0 = tic;
            for k = 1:numel(obj.Devices)
                stream = obj.Devices{k}.Stream;
                if isempty(stream)
                    continue
                end
                while toc(t0) < budgetSeconds
                    [ok, data, width, height] = stream.TryDequeueExport();
                    if ~ok
                        break
                    end
                    try
                        writeVideo(obj.Writers{k}, reshape(uint8(data), double(width), double(height))');
                        n = n + 1;
                    catch me
                        obj.Errors{end + 1} = sprintf('%s: %s', obj.Devices{k}.Serial, me.message);
                    end
                end
            end
        end

        function files = finish(obj)
            %FINISH Drain everything, close VideoWriters; returns video file names.
            files = cell(1, numel(obj.Writers));
            obj.stopTimer();
            obj.drain(Inf);
            for k = 1:numel(obj.Writers)
                writer = obj.Writers{k};
                close(writer);
                files{k} = fullfile(writer.Path, writer.Filename);
                if ~isempty(obj.Devices{k}.Stream)
                    obj.Devices{k}.Stream.ClearExport();
                end
            end
            obj.Writers = {};
            obj.Devices = {};
            if ~isempty(obj.Errors)
                warning('spincam:recorder:writeErrors', 'VideoWriter errors: %s', strjoin(obj.Errors, ' | '));
            end
        end

        function abort(obj)
            obj.stopTimer();
            for k = 1:numel(obj.Writers)
                try
                    close(obj.Writers{k});
                catch
                end
            end
            obj.Writers = {};
            obj.Devices = {};
        end

        function s = toStruct(obj)
            s = struct();
            names = {'Format', 'Quality', 'H264BitrateMbps', 'H264Crf', 'FrameRate', 'MaxFileSizeMB', ...
                'QueueSeconds', 'MaxQueueMB', 'CsvExtended', 'ScrubEmbeddedPixels'};
            for k = 1:numel(names)
                s.(names{k}) = obj.(names{k});
            end
        end

        function delete(obj)
            obj.abort();
        end
    end

    methods (Access = private)
        function e = netFormat(obj)
            switch obj.Format
                case 'avi-mjpeg'
                    e = SpinCam.VideoFormat.AviMjpg;
                case 'avi-raw'
                    e = SpinCam.VideoFormat.AviUncompressed;
                case 'mp4-h264'
                    e = SpinCam.VideoFormat.Mp4H264;
                case 'raw'
                    e = SpinCam.VideoFormat.Raw;
                case {'matlab-avi', 'matlab-mjpeg'}
                    e = SpinCam.VideoFormat.MatlabExport;
                otherwise
                    e = SpinCam.VideoFormat.None;
            end
        end

        function stopTimer(obj)
            if ~isempty(obj.DrainTimer) && isvalid(obj.DrainTimer)
                stop(obj.DrainTimer);
                delete(obj.DrainTimer);
            end
            obj.DrainTimer = [];
        end
    end

    methods (Static, Access = private)
        function [width, height] = frameSize(device)
            width = 1280;
            height = 1024;
            try
                width = device.NodeMap.get('Width');
                height = device.NodeMap.get('Height');
            catch
            end
        end
    end
end
