function aviPath = rawToAvi(rawPath, aviPath, opts)
%RAWTOAVI Convert a spincam .raw recording to AVI with MATLAB VideoWriter.
%   spincam.io.rawToAvi('day1_cam24226887.raw')                       -> day1_cam24226887.avi (Grayscale AVI, lossless)
%   spincam.io.rawToAvi(rawPath, aviPath, 'Profile', 'Motion JPEG AVI', 'Quality', 90)
%   Frame order and count are preserved, so VideoFrameIndex in the CSV still applies.
arguments
    rawPath {mustBeTextScalar}
    aviPath {mustBeTextScalar} = ''
    opts.Profile (1,:) char {mustBeMember(opts.Profile, {'Grayscale AVI', 'Motion JPEG AVI'})} = 'Grayscale AVI'
    opts.Quality (1,1) double {mustBeInteger, mustBeInRange(opts.Quality, 1, 100)} = 90
    opts.FrameRate double = []
    opts.ChunkFrames (1,1) double {mustBeInteger, mustBePositive} = 500
end
reader = spincam.io.RawVideoReader(rawPath);
if isempty(aviPath)
    [folder, name] = fileparts(reader.Path);
    aviPath = fullfile(folder, [name '.avi']);
end
aviPath = spincam.internal.toWindowsPath(aviPath);
writer = VideoWriter(aviPath, opts.Profile);
if ~isempty(opts.FrameRate)
    writer.FrameRate = opts.FrameRate;
elseif reader.FrameRate > 0
    writer.FrameRate = reader.FrameRate;
end
if strcmp(opts.Profile, 'Motion JPEG AVI')
    writer.Quality = opts.Quality;
end
open(writer);
closer = onCleanup(@() close(writer));
for first = 1:opts.ChunkFrames:reader.NumFrames
    last = min(reader.NumFrames, first + opts.ChunkFrames - 1);
    frames = reader.read([first last]);
    writeVideo(writer, reshape(frames, reader.Height, reader.Width, 1, []));
end
end
