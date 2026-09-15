classdef RawVideoReader < handle
    %RAWVIDEOREADER Read lossless spincam .raw recordings (Recorder.Format = 'raw').
    %   r = spincam.io.RawVideoReader('D:\data\day1_cam24226887.raw');
    %   img = r.read(1);             first frame, Height-by-Width uint8
    %   clip = r.read([100 199]);    frames 100..199, Height-by-Width-by-100 uint8
    %
    %   File layout: frames concatenated row-major, 8 bits per pixel, frame i (1-based)
    %   starts at byte (i-1)*Width*Height. Geometry comes from the <file>.raw.json sidecar;
    %   NumFrames is derived from the file size, so files from an interrupted recording
    %   are still readable. VideoFrameIndex in the frame CSV is the 0-based frame index.

    properties (SetAccess = private)
        Path char = ''
        Width double = 0
        Height double = 0
        NumFrames double = 0
        FrameRate double = NaN
        CameraId char = ''
    end

    properties (Access = private)
        Fid = -1
    end

    methods
        function obj = RawVideoReader(path)
            arguments
                path {mustBeTextScalar}
            end
            obj.Path = spincam.internal.toWindowsPath(path);
            sidecar = [obj.Path '.json'];
            if ~isfile(obj.Path)
                error('spincam:io:missingFile', 'File not found: %s', obj.Path);
            end
            if ~isfile(sidecar)
                error('spincam:io:missingFile', 'Sidecar not found: %s', sidecar);
            end
            meta = jsondecode(fileread(sidecar));
            obj.Width = double(meta.width);
            obj.Height = double(meta.height);
            obj.FrameRate = double(meta.frameRate);
            obj.CameraId = char(meta.cameraId);
            info = dir(obj.Path);
            obj.NumFrames = floor(info.bytes / (obj.Width * obj.Height));
            obj.Fid = fopen(obj.Path, 'r');
            if obj.Fid < 0
                error('spincam:io:openFailed', 'Cannot open %s.', obj.Path);
            end
        end

        function frames = read(obj, index)
            %READ Frame INDEX (scalar) or the inclusive range [FIRST LAST], 1-based.
            arguments
                obj
                index (1,:) double {mustBeInteger, mustBePositive}
            end
            first = index(1);
            last = index(end);
            if numel(index) > 2 || last < first || last > obj.NumFrames
                error('spincam:io:badIndex', 'Frame index must be a scalar or [first last] within 1..%d.', obj.NumFrames);
            end
            count = last - first + 1;
            pixels = obj.Width * obj.Height;
            fseek(obj.Fid, (first - 1) * pixels, 'bof');
            data = fread(obj.Fid, pixels * count, '*uint8');
            if numel(data) ~= pixels * count
                error('spincam:io:shortRead', 'Unexpected end of file reading frames %d-%d.', first, last);
            end
            frames = permute(reshape(data, obj.Width, obj.Height, count), [2 1 3]);
        end

        function delete(obj)
            if obj.Fid >= 0
                fclose(obj.Fid);
            end
        end
    end
end
