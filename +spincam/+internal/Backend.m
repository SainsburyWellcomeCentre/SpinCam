classdef (Abstract) Backend < handle
    %BACKEND Source of cameras for spincam.CameraManager.

    properties (Abstract, SetAccess = protected)
        Name char
    end

    methods (Abstract)
        info = listCameras(obj)     % struct array: Serial, Model, Firmware, Speed
        device = open(obj, serial)  % spincam.CameraDevice
        close(obj, device)
        shutdown(obj)
    end
end
