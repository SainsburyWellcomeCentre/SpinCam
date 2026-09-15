classdef EngineSyntheticTest < matlab.unittest.TestCase
    %ENGINESYNTHETICTEST SpinCamEngine threads, CSV and video sinks with a synthetic camera.
    %   Ground truth (SyntheticFrameSource): TTL = mod(floor(counter/half), 2) on Line0,
    %   counters with mod(counter, DropEvery) == DropEvery-1 are lost, every
    %   IncompleteEvery-th delivered frame is incomplete. Embedded header: frame counter at
    %   byte 0, GPIO word at byte 4.

    properties
        OutDir
    end

    methods (TestClassSetup)
        function requireEngine(tc)
            tc.assumeTrue(ispc && NET.isNETSupported, 'Requires Windows with .NET.');
            tc.assumeNotEmpty(spincam.internal.NativeEngine.spinnakerBin(), 'Requires Spinnaker assemblies.');
            spincam.internal.NativeEngine.load();
        end
    end

    methods (TestMethodSetup)
        function makeOutputFolder(tc)
            tc.OutDir = testOutputFolder('EngineSyntheticTest');
            tc.addTeardown(@() removeFolder(tc.OutDir));
        end
    end

    methods (Test)
        function csvColumnsInContractOrder(tc)
            [~, ~, csvPath] = tc.record('Seconds', 0.5);
            header = strsplit(firstLine(csvPath), ',');
            tc.verifyEqual(header(1:6), {'FrameNumber', 'CameraID', 'HardwareTimestamp_us', ...
                'HostTimestamp_datetime', 'TTL_State', 'DroppedFrameFlag'});
            tc.verifyEqual(header(7:end), {'DeviceFrameID', 'EmbeddedFrameCounter', 'FramesMissedBefore', ...
                'HostTime_s', 'GPIO_LineStatus', 'TTL_Source', 'VideoFrameIndex', 'WriterDropFlag', 'IncompleteFlag'});
        end

        function compactCsvHasOnlyRequiredColumns(tc)
            [~, ~, csvPath] = tc.record('Seconds', 0.4, 'CsvExtended', false);
            header = strsplit(firstLine(csvPath), ',');
            tc.verifyEqual(numel(header), 6);
        end

        function frameCountsAndTimestamps(tc)
            fps = 100;
            [T, summary] = tc.record('Fps', fps, 'Seconds', 1.5);
            n = height(T);
            tc.verifyGreaterThan(n, 0.7 * 1.5 * fps);
            tc.verifyLessThan(n, 1.3 * 1.5 * fps);
            tc.verifyEqual(T.FrameNumber, (0:n - 1)');
            tc.verifyEqual(summary.framesLogged, n);
            tc.verifyEqual(median(diff(T.HardwareTimestamp_us)), 1e6 / fps, 'RelTol', 0.1);
            tc.verifyTrue(all(diff(T.HostTime_s) > 0));
            tc.verifyTrue(all(diff(T.HostTimestamp_datetime) >= 0));
            tc.verifyTrue(all(T.CameraID == "SIM1"));
            tc.verifyEqual(sum(T.DroppedFrameFlag), 0);
        end

        function ttlMatchesGroundTruth(tc)
            half = 7;
            T = tc.record('Half', half, 'Seconds', 1.2);
            expected = mod(floor(T.EmbeddedFrameCounter / half), 2);
            tc.verifyEqual(T.TTL_State, expected);
            tc.verifyTrue(all(T.TTL_Source == "embedded"));
            tc.verifyEqual(bitand(T.GPIO_LineStatus, 1), T.TTL_State);
            tc.verifyTrue(all(bitand(T.GPIO_LineStatus, 8) == 8), 'Idle Line3 high is preserved');
            tc.verifyGreaterThan(nnz(diff(T.TTL_State) ~= 0), 2, 'The recording must contain TTL edges');
        end

        function droppedFramesDetected(tc)
            dropEvery = 7;
            [T, summary] = tc.record('DropEvery', dropEvery, 'Seconds', 1.5);
            tc.verifyFalse(any(mod(T.EmbeddedFrameCounter, dropEvery) == dropEvery - 1));
            tc.verifyEqual(diff(T.DeviceFrameID), 1 + T.FramesMissedBefore(2:end));
            tc.verifyEqual(diff(T.EmbeddedFrameCounter), 1 + T.FramesMissedBefore(2:end));
            tc.verifyGreaterThan(sum(T.FramesMissedBefore), 5);
            tc.verifyEqual(T.DroppedFrameFlag, double(T.FramesMissedBefore > 0));
            tc.verifyEqual(summary.framesMissed, sum(T.FramesMissedBefore));
        end

        function incompleteFramesFlaggedAndNotWritten(tc)
            [T, summary] = tc.record('IncompleteEvery', 5, 'Seconds', 1.2, ...
                'Format', SpinCam.VideoFormat.AviUncompressed);
            bad = T.IncompleteFlag == 1;
            tc.verifyGreaterThan(nnz(bad), 5);
            tc.verifyTrue(all(T.VideoFrameIndex(bad) == -1));
            tc.verifyTrue(all(T.DroppedFrameFlag(bad) == 1));
            tc.verifyTrue(all(T.TTL_State(bad) == -1));
            tc.verifyEqual(sum(T.FramesMissedBefore), 0, 'Incomplete frames are not lost frames');
            tc.verifyEqual(T.VideoFrameIndex(~bad), (0:nnz(~bad) - 1)');
            tc.verifyEqual(summary.framesWritten, nnz(~bad));
        end

        function recordingGateOpensOnFirstRisingEdge(tc)
            half = 15;
            [T, summary] = tc.record('Half', half, 'Fps', 100, 'Seconds', 1.5, ...
                'Gate', SpinCam.RecordGate.FirstRisingEdge);
            tc.verifyTrue(summary.gateOpen);
            tc.verifyNotEmpty(T);
            first = T.EmbeddedFrameCounter(1);
            tc.verifyEqual(T.TTL_State(1), 1);
            tc.verifyEqual(mod(first, half), 0, 'First recorded frame is the first high frame');
        end

        function uncompressedVideoFramesMatchPattern(tc)
            % SpinVideo "uncompressed" AVI is I420 (yuv420p): decoded gray levels are not
            % bit-exact, so verify frame count and image content rather than pixel values.
            [T, summary] = tc.record('Seconds', 0.8, 'Format', SpinCam.VideoFormat.AviUncompressed);
            tc.assertNotEmpty(summary.files);
            files = cellstr(summary.files);
            reader = VideoReader(files{1});
            tc.verifyEqual(reader.NumFrames, summary.framesWritten);
            tc.verifyEqual([reader.Height reader.Width], [240 320]);
            frame = double(read(reader, 1));
            id = T.DeviceFrameID(T.VideoFrameIndex == 0);
            matching = correlation(frame(:, :, 1), renderPattern(id));
            shifted = correlation(frame(:, :, 1), renderPattern(id + 40));
            tc.verifyGreaterThan(matching, 0.98);
            tc.verifyGreaterThan(matching, shifted + 0.1);
        end

        function scrubbedPixelsCopyRowBelow(tc)
            [~, summary] = tc.record('Seconds', 0.5, 'Format', SpinCam.VideoFormat.AviUncompressed);
            files = cellstr(summary.files);
            frame = read(VideoReader(files{1}), 1);
            tc.verifyEqual(frame(1, 1:8, 1), frame(2, 1:8, 1));
        end

        function mjpegVideoFrameCount(tc)
            [~, summary] = tc.record('Seconds', 1.0, 'Format', SpinCam.VideoFormat.AviMjpg);
            files = cellstr(summary.files);
            tc.assertNumElements(files, 1);
            tc.verifyTrue(endsWith(files{1}, '.avi'));
            reader = VideoReader(files{1});
            tc.verifyEqual(reader.NumFrames, summary.framesWritten);
            tc.verifyEqual(summary.writerDrops, 0);
        end

        function rawRecordingIsLosslessAndIndexed(tc)
            [T, summary] = tc.record('Seconds', 0.8, 'Format', SpinCam.VideoFormat.Raw, 'Scrub', false);
            files = cellstr(summary.files);
            tc.assertNumElements(files, 1);
            tc.verifyTrue(endsWith(files{1}, '.raw'));
            reader = spincam.io.RawVideoReader(files{1});
            tc.verifyEqual(reader.NumFrames, summary.framesWritten);
            tc.verifyEqual([reader.Height reader.Width], [240 320]);
            tc.verifyEqual(reader.CameraId, 'SIM1');
            written = T(T.VideoFrameIndex >= 0, :);
            clip = reader.read([1 reader.NumFrames]);
            counters = zeros(reader.NumFrames, 1);
            for k = 1:reader.NumFrames
                counters(k) = double(spincam.internal.FrameInfo.readBigEndian32(clip(1, 1:8, k), 0));
            end
            tc.verifyEqual(counters, written.EmbeddedFrameCounter);
            reference = renderPattern(written.DeviceFrameID(1));
            tc.verifyEqual(double(clip(60:end, :, 1)), reference(60:end, :), 'Pixels are bit-exact');
        end

        function rawConvertsToLosslessAvi(tc)
            [~, summary] = tc.record('Seconds', 0.4, 'Format', SpinCam.VideoFormat.Raw);
            rawFile = char(cellstr(summary.files));
            avi = spincam.io.rawToAvi(rawFile);
            reader = spincam.io.RawVideoReader(rawFile);
            video = VideoReader(avi);
            tc.verifyEqual(video.NumFrames, reader.NumFrames);
            frame = read(video, 1);
            tc.verifyEqual(frame(:, :, 1), reader.read(1));
            delete(reader);
        end

        function exportedFramesMatchCsvRowsExactly(tc)
            % Lossless path: the embedded counter in each exported frame must equal the CSV
            % row that carries the same VideoFrameIndex.
            [T, summary, ~, stream] = tc.record('Seconds', 0.8, 'Format', SpinCam.VideoFormat.MatlabExport, ...
                'Scrub', false);
            indices = [];
            counters = [];
            while true
                [ok, data, width, height, index] = stream.TryDequeueExport();
                if ~ok
                    break
                end
                bytes = uint8(data);
                tc.verifyEqual(numel(bytes), double(width) * double(height));
                indices(end + 1) = double(index); %#ok<AGROW>
                counters(end + 1) = double(spincam.internal.FrameInfo.readBigEndian32(bytes, 0)); %#ok<AGROW>
            end
            tc.verifyEqual(indices, 0:summary.framesWritten - 1);
            written = T(T.VideoFrameIndex >= 0, :);
            tc.verifyEqual(written.VideoFrameIndex', indices);
            tc.verifyEqual(counters(:), written.EmbeddedFrameCounter);
        end

        function writerOverflowIsFlagged(tc)
            [T, summary] = tc.record('Seconds', 0.8, 'Format', SpinCam.VideoFormat.MatlabExport, ...
                'ExportCapacity', 3);
            tc.verifyEqual(summary.framesWritten, 3);
            tc.verifyGreaterThan(summary.writerDrops, 10);
            dropped = T.WriterDropFlag == 1;
            tc.verifyEqual(nnz(dropped), summary.writerDrops);
            tc.verifyTrue(all(T.VideoFrameIndex(dropped) == -1));
            tc.verifyTrue(all(T.DroppedFrameFlag(dropped) == 1));
        end

        function polledTtlTracksGroundTruth(tc)
            half = 20;
            T = tc.record('Half', half, 'Fps', 60, 'Seconds', 1.5, 'TtlMode', SpinCam.TtlSource.Polled);
            valid = T.TTL_State >= 0;
            tc.verifyTrue(all(T.TTL_Source(valid) == "polled"));
            expected = mod(floor(T.EmbeddedFrameCounter(valid) / half), 2);
            agreement = mean(T.TTL_State(valid) == expected);
            tc.verifyGreaterThan(agreement, 0.8);
        end

        function previewAndStats(tc)
            src = SpinCam.SyntheticFrameSource('SIM2', int32(320), int32(240), 50);
            stream = SpinCam.CameraStream(src);
            tc.addTeardown(@() stream.Dispose());
            stream.EmbeddedFrameCounterOffset = int32(0);
            stream.EmbeddedGpioOffset = int32(4);
            stream.Start();
            pause(0.6);
            [data, width, height, frameId, ~, sequence1] = stream.GetLatestFrame();
            pause(0.2);
            [~, ~, ~, ~, ~, sequence2] = stream.GetLatestFrame();
            stats = jsondecode(char(stream.GetStatsJson()));
            stream.Stop();
            tc.verifyEqual([double(width) double(height)], [320 240]);
            tc.verifyEqual(double(data.Length), 320 * 240);
            tc.verifyGreaterThanOrEqual(double(frameId), 0);
            tc.verifyGreaterThan(double(sequence2), double(sequence1));
            tc.verifyTrue(stats.running);
            tc.verifyEqual(stats.fps, 50, 'RelTol', 0.3);
            tc.verifyGreaterThan(stats.framesReceived, 15);
        end

        function hostClockIsMonotonicAndAnchored(tc)
            t1 = double(SpinCam.HostClock.NowSeconds());
            pause(0.05);
            t2 = double(SpinCam.HostClock.NowSeconds());
            tc.verifyGreaterThan(t2 - t1, 0.04);
            anchor = datetime(char(SpinCam.HostClock.AnchorIso), 'InputFormat', ...
                'yyyy-MM-dd''T''HH:mm:ss.SSSSSSxxx', 'TimeZone', 'local');
            now = datetime('now', 'TimeZone', 'local');
            tc.verifyLessThan(abs(seconds(now - (anchor + seconds(t2)))), 1);
        end

        function writerBenchmarkRuns(tc)
            json = SpinCam.Engine.BenchmarkWriter(fullfile(tc.OutDir, 'bench'), SpinCam.VideoFormat.AviMjpg, ...
                int32(320), int32(240), int32(20), 30, int32(75));
            r = jsondecode(char(json));
            tc.verifyEqual(r.frames, 20);
            tc.verifyGreaterThan(r.fps, 0);
            tc.verifyTrue(isfile(char(cellstr(r.files))));
        end
    end

    methods (Access = private)
        function [T, summary, csvPath, stream] = record(tc, opts)
            arguments
                tc
                opts.Fps (1,1) double = 100
                opts.Seconds (1,1) double = 1
                opts.Half (1,1) double = 10
                opts.DropEvery (1,1) double = 0
                opts.IncompleteEvery (1,1) double = 0
                opts.Format = SpinCam.VideoFormat.None
                opts.Gate = SpinCam.RecordGate.None
                opts.TtlMode = SpinCam.TtlSource.Embedded
                opts.CsvExtended (1,1) logical = true
                opts.Scrub (1,1) logical = true
                opts.ExportCapacity (1,1) double = 1000
            end
            src = SpinCam.SyntheticFrameSource('SIM1', int32(320), int32(240), opts.Fps);
            src.TtlHalfPeriodFrames = int32(opts.Half);
            src.DropEvery = int32(opts.DropEvery);
            src.IncompleteEvery = int32(opts.IncompleteEvery);
            stream = SpinCam.CameraStream(src);
            tc.addTeardown(@() stream.Dispose());
            stream.TtlMode = opts.TtlMode;
            stream.TtlLine = int32(0);
            stream.EmbeddedFrameCounterOffset = int32(0);
            stream.EmbeddedGpioOffset = int32(4);
            stream.ScrubEmbeddedPixels = opts.Scrub;
            stream.Start();

            name = sprintf('rec%d', randi(1e6));
            options = SpinCam.RecordingOptions();
            options.CameraId = 'SIM1';
            options.VideoPath = fullfile(tc.OutDir, name);
            options.CsvPath = fullfile(tc.OutDir, [name '_frames.csv']);
            options.Format = opts.Format;
            options.FrameRate = opts.Fps;
            options.Gate = opts.Gate;
            options.CsvExtended = opts.CsvExtended;
            options.ExportCapacityFrames = int32(opts.ExportCapacity);
            stream.StartRecording(options);
            pause(opts.Seconds);
            summary = jsondecode(char(stream.StopRecording(int32(60000))));
            stream.Stop();
            csvPath = char(options.CsvPath);
            T = [];
            if opts.CsvExtended
                T = spincam.io.readFrameLog(csvPath);
            end
        end
    end
end

function folder = testOutputFolder(name)
folder = fullfile(spincam.internal.NativeEngine.projectRoot(), 'tests', '_output', ...
    sprintf('%s_%s_%d', name, char(datetime('now', 'Format', 'HHmmssSSS')), randi(1e6)));
mkdir(folder);
end

function img = renderPattern(frameId)
source = SpinCam.SyntheticFrameSource('reference', int32(320), int32(240), 30);
buffer = NET.createArray('System.Byte', 320 * 240);
source.Render(int64(frameId), buffer);
img = reshape(double(uint8(buffer)), 320, 240)';
end

function r = correlation(a, b)
c = corrcoef(a(:), b(:));
r = c(1, 2);
end

function removeFolder(folder)
if isfolder(folder)
    rmdir(folder, 's');
end
end

function line = firstLine(path)
fid = fopen(path, 'r');
closer = onCleanup(@() fclose(fid));
line = strtrim(fgetl(fid));
end
