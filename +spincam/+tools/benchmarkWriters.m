function T = benchmarkWriters(opts)
%BENCHMARKWRITERS Encoder throughput of each video format with synthetic frames.
%   T = spincam.tools.benchmarkWriters() encodes 300 full-size (1280x1024) frames
%   per format and reports frames/s and whether one camera at FrameRate is sustainable.
%   Native formats are measured inside the engine (encoder time only); MATLAB
%   formats include writeVideo overhead.
arguments
    opts.Width (1,1) double {mustBeInteger, mustBePositive} = 1280
    opts.Height (1,1) double {mustBeInteger, mustBePositive} = 1024
    opts.Frames (1,1) double {mustBeInteger, mustBePositive} = 300
    opts.FrameRate (1,1) double {mustBePositive} = 150
    opts.Quality (1,1) double {mustBeInteger, mustBeInRange(opts.Quality, 1, 100)} = 75
    opts.JpegQuality (1,1) double {mustBeInteger, mustBeInRange(opts.JpegQuality, 1, 100)} = 30
    opts.Folder (1,:) char = fullfile(spincam.internal.NativeEngine.projectRoot(), 'tests', '_output', 'benchmark')
    opts.KeepFiles (1,1) logical = false
end
spincam.internal.NativeEngine.load();
if ~isfolder(opts.Folder)
    mkdir(opts.Folder);
end
native = {'raw', SpinCam.VideoFormat.Raw; 'avi-raw', SpinCam.VideoFormat.AviUncompressed; ...
    'avi-mjpeg-mt', SpinCam.VideoFormat.AviMjpgParallel; 'avi-mjpeg', SpinCam.VideoFormat.AviMjpg; ...
    'mp4-h264', SpinCam.VideoFormat.Mp4H264};
formats = [native(:, 1)', {'matlab-avi', 'matlab-mjpeg'}];
n = numel(formats);
Format = formats(:); EncodeFps = nan(n, 1); MBps = nan(n, 1); FileMB = nan(n, 1);
Sustainable = false(n, 1); Note = repmat({''}, n, 1);

for k = 1:size(native, 1)
    stem = fullfile(opts.Folder, ['bench_' strrep(native{k, 1}, '-', '_')]);
    try
        quality = opts.Quality;
        if strcmp(native{k, 1}, 'avi-mjpeg-mt')
            quality = opts.JpegQuality;
        end
        r = jsondecode(char(SpinCam.Engine.BenchmarkWriter(stem, native{k, 2}, int32(opts.Width), ...
            int32(opts.Height), int32(opts.Frames), opts.FrameRate, int32(quality))));
        EncodeFps(k) = r.fps;
        FileMB(k) = r.bytes / 2^20;
        MBps(k) = r.bytes / 2^20 / r.seconds;
        cleanup(cellstr(r.files), opts.KeepFiles);
    catch me
        Note{k} = strtok(me.message, newline);
    end
end

frames = syntheticFrames(opts.Width, opts.Height, min(opts.Frames, 120));
profiles = {'Grayscale AVI', 'Motion JPEG AVI'};
for j = 1:2
    k = size(native, 1) + j;
    file = fullfile(opts.Folder, sprintf('bench_matlab_%d.avi', j));
    try
        writer = VideoWriter(file, profiles{j});
        writer.FrameRate = opts.FrameRate;
        if j == 2
            writer.Quality = opts.Quality;
        end
        open(writer);
        t0 = tic;
        for f = 1:size(frames, 3)
            writeVideo(writer, frames(:, :, f));
        end
        close(writer);
        elapsed = toc(t0);
        EncodeFps(k) = size(frames, 3) / elapsed;
        info = dir(file);
        FileMB(k) = info.bytes / 2^20;
        MBps(k) = FileMB(k) / elapsed;
        cleanup({file}, opts.KeepFiles);
    catch me
        Note{k} = strtok(me.message, newline);
    end
end
if ~opts.KeepFiles && isfolder(opts.Folder) && numel(dir(opts.Folder)) <= 2
    rmdir(opts.Folder);
end
Sustainable = EncodeFps >= opts.FrameRate;
T = table(Format, EncodeFps, Sustainable, MBps, FileMB, Note);
fprintf('Frames %dx%d, target %g fps per camera:\n', opts.Width, opts.Height, opts.FrameRate);
disp(T);
end

function frames = syntheticFrames(width, height, count)
[x, y] = meshgrid(1:width, 1:height);
frames = zeros(height, width, count, 'uint8');
for f = 1:count
    frames(:, :, f) = uint8(mod(x / 4 + y / 2 + 3 * f, 256));
end
end

function cleanup(files, keep)
if keep
    return
end
for k = 1:numel(files)
    for candidate = {files{k}, [files{k} '.json']}
        if isfile(candidate{1})
            delete(candidate{1});
        end
    end
end
end
