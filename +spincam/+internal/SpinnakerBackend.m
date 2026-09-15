classdef SpinnakerBackend < spincam.internal.Backend
    %SPINNAKERBACKEND Real cameras through Spinnaker .NET.

    properties (SetAccess = protected)
        Name char = 'spinnaker'
    end

    properties (SetAccess = private)
        System
    end

    methods
        function obj = SpinnakerBackend()
            obj.System = spincam.internal.SpinnakerSystem.instance();
            obj.System.acquire();
        end

        function info = listCameras(obj)
            info = obj.System.enumerate();
        end

        function device = open(obj, serial)
            serial = char(serial);
            cam = obj.System.openCamera(serial);
            try
                label = ['cam ' serial];
                nodeMap = spincam.internal.SpinnakerNodeMap(cam.GetNodeMap(), label);
                streamNodeMap = spincam.internal.SpinnakerNodeMap(cam.GetTLStreamNodeMap(), label);
                registers = spincam.internal.SpinnakerRegisterPort(cam, label);
                source = SpinCam.SpinnakerFrameSource(cam, serial);
                device = spincam.CameraDevice(serial, nodeMap, streamNodeMap, registers, source, false);
            catch me
                obj.System.closeCamera(serial);
                rethrow(me);
            end
        end

        function close(obj, device)
            serial = device.Serial;
            device.detach();
            obj.System.closeCamera(serial);
        end

        function shutdown(obj)
            if ~isempty(obj.System) && isvalid(obj.System)
                obj.System.release();
            end
            obj.System = [];
        end
    end
end
