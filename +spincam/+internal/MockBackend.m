classdef MockBackend < spincam.internal.Backend
    %MOCKBACKEND Simulated Chameleon3 cameras for development and tests.
    %   Node maps and registers are MATLAB mocks (MockNodeMap/MockRegisterPort).
    %   Frames come from the C# SyntheticFrameSource, so streaming, TTL decoding,
    %   CSV logging and video writing run through the real engine. Without the
    %   .NET engine (non-Windows), property and sync logic still work but
    %   streaming raises spincam:stream:unavailable.
    %
    %   Synthetic TTL: square wave on the configured TtlLine, TtlHalfPeriodFrames
    %   frames high then low. Trigger modes are not simulated (frames free-run).

    properties (SetAccess = protected)
        Name char = 'mock'
    end

    properties (SetAccess = private)
        Serials cell = {}
        FrameRate double = 60
        Resolution double = [1024 1280]
        GammaAvailable logical = false
        TtlHalfPeriodFrames double = 30
        DropEvery double = 0
        IncompleteEvery double = 0
        EngineAvailable logical = false
        Open cell = {}
    end

    methods
        function obj = MockBackend(opts)
            arguments
                opts.NumCameras (1,1) double {mustBeInteger, mustBePositive} = 2
                opts.FrameRate (1,1) double {mustBePositive} = 60
                opts.Resolution (1,2) double {mustBeInteger, mustBePositive} = [1024 1280]
                opts.GammaAvailable (1,1) logical = false
                opts.TtlHalfPeriodFrames (1,1) double {mustBeInteger, mustBePositive} = 30
                opts.DropEvery (1,1) double {mustBeInteger, mustBeNonnegative} = 0
                opts.IncompleteEvery (1,1) double {mustBeInteger, mustBeNonnegative} = 0
            end
            obj.Serials = arrayfun(@(k) sprintf('9000%04d', k), 1:opts.NumCameras, 'UniformOutput', false);
            obj.FrameRate = opts.FrameRate;
            obj.Resolution = opts.Resolution;
            obj.GammaAvailable = opts.GammaAvailable;
            obj.TtlHalfPeriodFrames = opts.TtlHalfPeriodFrames;
            obj.DropEvery = opts.DropEvery;
            obj.IncompleteEvery = opts.IncompleteEvery;
            try
                spincam.internal.NativeEngine.load();
                obj.EngineAvailable = true;
            catch me
                warning('spincam:mock:noEngine', ...
                    'Mock cameras cannot stream (engine unavailable): %s', me.message);
            end
        end

        function info = listCameras(obj)
            n = numel(obj.Serials);
            info = repmat(struct('Serial', '', 'Model', 'Chameleon3 CM3-U3-13Y3M (mock)', ...
                'Firmware', 'FW:v1.13.3.00 FPGA:v2.02', 'Speed', 'SuperSpeed'), 1, n);
            for k = 1:n
                info(k).Serial = obj.Serials{k};
            end
        end

        function device = open(obj, serial)
            serial = char(serial);
            if ~any(strcmp(obj.Serials, serial))
                error('spincam:camera:notFound', 'Camera %s was not found.', serial);
            end
            if any(strcmp(obj.Open, serial))
                error('spincam:camera:alreadyOpen', 'Camera %s is already open.', serial);
            end
            height = obj.Resolution(1);
            width = obj.Resolution(2);
            nodeMap = spincam.internal.MockNodeMap.cm3('Serial', serial, 'Width', width, ...
                'Height', height, 'GammaAvailable', obj.GammaAvailable);
            nodeMap.setRaw('AcquisitionFrameRate', obj.FrameRate);
            nodeMap.setRaw('ExposureTime', min(6573.56, floor(0.9908e6 / obj.FrameRate)));
            streamNodeMap = spincam.internal.MockNodeMap.cm3Stream();
            registers = spincam.internal.MockRegisterPort(serial);
            source = [];
            if obj.EngineAvailable
                source = SpinCam.SyntheticFrameSource(serial, int32(width), int32(height), obj.FrameRate);
                source.TtlHalfPeriodFrames = int32(obj.TtlHalfPeriodFrames);
                source.DropEvery = int32(obj.DropEvery);
                source.IncompleteEvery = int32(obj.IncompleteEvery);
            end
            device = spincam.CameraDevice(serial, nodeMap, streamNodeMap, registers, source, true);
            obj.Open{end + 1} = serial;
        end

        function close(obj, device)
            obj.Open(strcmp(obj.Open, device.Serial)) = [];
            device.detach();
        end

        function shutdown(obj)
            obj.Open = {};
        end
    end
end
