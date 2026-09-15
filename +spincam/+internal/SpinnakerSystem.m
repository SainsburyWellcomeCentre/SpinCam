classdef SpinnakerSystem < handle
    %SPINNAKERSYSTEM Reference-counted owner of the Spinnaker ManagedSystem singleton.
    %   Every camera list obtained from the system is retained until shutdown so
    %   camera handles stay valid; shutdown DeInits/Disposes cameras, clears lists
    %   and disposes the system (leaking any of these hangs MATLAB at exit).

    properties (SetAccess = private)
        NetSystem = []
        LibraryVersion char = ''
    end

    properties (Access = private)
        Users = 0
        Lists = {}
        OpenCameras
    end

    methods (Static)
        function obj = instance()
            persistent singleton
            if isempty(singleton) || ~isvalid(singleton) || isempty(singleton.NetSystem)
                singleton = spincam.internal.SpinnakerSystem();
            end
            obj = singleton;
        end
    end

    methods (Access = private)
        function obj = SpinnakerSystem()
            spincam.internal.NativeEngine.load();
            obj.NetSystem = SpinnakerNET.ManagedSystem();
            v = obj.NetSystem.GetLibraryVersion();
            obj.LibraryVersion = sprintf('%d.%d.%d.%d', v.major, v.minor, v.type, v.build);
            obj.OpenCameras = containers.Map('KeyType', 'char', 'ValueType', 'any');
        end
    end

    methods
        function acquire(obj)
            obj.Users = obj.Users + 1;
        end

        function release(obj)
            obj.Users = max(0, obj.Users - 1);
            if obj.Users == 0
                obj.shutdown();
            end
        end

        function info = enumerate(obj)
            %ENUMERATE Identity of every attached camera (cameras are not initialized).
            list = obj.newList();
            n = double(list.Count);
            info = repmat(struct('Serial', '', 'Model', '', 'Firmware', '', 'Speed', ''), 1, n);
            for k = 1:n
                cam = list.GetByIndex(uint32(k - 1));
                nm = spincam.internal.SpinnakerNodeMap(cam.GetTLDeviceNodeMap());
                info(k).Serial = readOr(nm, 'DeviceSerialNumber', '');
                info(k).Model = readOr(nm, 'DeviceModelName', '');
                info(k).Firmware = readOr(nm, 'DeviceVersion', '');
                info(k).Speed = readOr(nm, 'DeviceCurrentSpeed', '');
            end
        end

        function cam = openCamera(obj, serial)
            serial = char(serial);
            if isKey(obj.OpenCameras, serial)
                error('spincam:camera:alreadyOpen', 'Camera %s is already open.', serial);
            end
            list = obj.newList();
            cam = list.GetBySerial(serial);
            if isempty(cam)
                error('spincam:camera:notFound', 'Camera %s was not found.', serial);
            end
            try
                cam.Init();
            catch me
                error('spincam:camera:initFailed', ['Initializing camera %s failed (is SpinView or ' ...
                    'another process using it?): %s'], serial, strtok(me.message, newline));
            end
            obj.OpenCameras(serial) = cam;
        end

        function closeCamera(obj, serial)
            serial = char(serial);
            if ~isKey(obj.OpenCameras, serial)
                return
            end
            cam = obj.OpenCameras(serial);
            remove(obj.OpenCameras, serial);
            try
                if cam.IsStreaming()
                    cam.EndAcquisition();
                end
            catch
            end
            try
                cam.DeInit();
            catch
            end
            try
                cam.Dispose();
            catch
            end
        end

        function shutdown(obj)
            if isempty(obj.NetSystem)
                return
            end
            serials = keys(obj.OpenCameras);
            for k = 1:numel(serials)
                obj.closeCamera(serials{k});
            end
            for k = 1:numel(obj.Lists)
                try
                    obj.Lists{k}.Clear();
                catch
                end
            end
            obj.Lists = {};
            try
                obj.NetSystem.Dispose();
            catch me
                warning('spincam:system:disposeFailed', 'Releasing the Spinnaker system failed: %s', ...
                    strtok(me.message, newline));
            end
            obj.NetSystem = [];
            obj.Users = 0;
        end

        function delete(obj)
            obj.shutdown();
        end
    end

    methods (Access = private)
        function list = newList(obj)
            list = obj.NetSystem.GetCameras();
            obj.Lists{end + 1} = list;
        end
    end
end

function v = readOr(nm, name, default)
v = default;
try
    if nm.has(name) && nm.isReadable(name)
        v = nm.get(name);
    end
catch
end
end
