function report = probeCameras(opts)
%PROBECAMERAS Print camera identity, key nodes, GPIO capabilities and IIDC registers.
%   report = spincam.tools.probeCameras() inspects every attached camera.
%   Read-only apart from LineSelector, which is restored. Close SpinView first.
arguments
    opts.Serials = {}
    opts.Quiet (1,1) logical = false
end
sys = spincam.internal.SpinnakerSystem.instance();
sys.acquire();
releaser = onCleanup(@() sys.release());
cameras = sys.enumerate();
if ~isempty(opts.Serials)
    cameras = cameras(ismember({cameras.Serial}, cellstr(opts.Serials)));
end
say(opts.Quiet, 'Spinnaker %s, %d camera(s)\n', sys.LibraryVersion, numel(cameras));

nodes = {'DeviceModelName', 'DeviceFirmwareVersion', 'DeviceVersion', 'DeviceTemperature', ...
    'PixelFormat', 'Width', 'Height', 'AcquisitionFrameRateAuto', 'AcquisitionFrameRateEnabled', ...
    'AcquisitionFrameRate', 'ExposureAuto', 'ExposureTime', 'GainAuto', 'Gain', 'BlackLevel', ...
    'GammaEnabled', 'Gamma', 'TriggerMode', 'TriggerSelector', 'TriggerSource', 'TriggerActivation', ...
    'ExposureMode', 'LineStatusAll', 'DeviceLinkThroughputLimit', 'DeviceMaxThroughput'};
registers = {'GPIO_CTRL', '1100'; 'GPIO_STRPAT_CTRL', '110C'; 'STRPAT_MASK_PIN_0', '1118'; ...
    'STRPAT_MASK_PIN_1', '1128'; 'STRPAT_MASK_PIN_2', '1138'; 'STRPAT_MASK_PIN_3', '1148'; ...
    'FRAME_INFO', '12F8'};

report = repmat(struct('Serial', '', 'Nodes', struct(), 'Lines', struct([]), 'Registers', struct()), ...
    1, numel(cameras));
for k = 1:numel(cameras)
    serial = cameras(k).Serial;
    report(k).Serial = serial;
    say(opts.Quiet, '\n=== Camera %s (%s, %s)\n', serial, cameras(k).Model, cameras(k).Speed);
    cam = sys.openCamera(serial);
    try
        nm = spincam.internal.SpinnakerNodeMap(cam.GetNodeMap(), serial);
        for n = 1:numel(nodes)
            if ~nm.has(nodes{n})
                continue
            end
            s = nm.info(nodes{n});
            report(k).Nodes.(nodes{n}) = s;
            say(opts.Quiet, '  %-28s %s\n', nodes{n}, describe(s));
        end

        original = nm.get('LineSelector');
        lineNames = nm.info('LineSelector').Entries;
        for n = 1:numel(lineNames)
            nm.set('LineSelector', lineNames{n});
            mode = nm.info('LineMode');
            source = nm.info('LineSource');
            line = struct('Line', lineNames{n}, 'LineMode', mode.Value, 'Modes', {mode.Entries}, ...
                'LineSource', source.Value, 'Sources', {source.Entries}, 'Status', nm.get('LineStatus'));
            report(k).Lines = [report(k).Lines, line];
            say(opts.Quiet, '  %s: mode %s {%s}, source %s {%s}, status %d\n', line.Line, line.LineMode, ...
                strjoin(line.Modes, '|'), valueText(line.LineSource), strjoin(line.Sources, '|'), line.Status);
        end
        nm.set('LineSelector', original);

        reg = spincam.internal.SpinnakerRegisterPort(cam, serial);
        for n = 1:size(registers, 1)
            try
                v = reg.read(hex2dec(registers{n, 2}));
                report(k).Registers.(registers{n, 1}) = v;
                say(opts.Quiet, '  0x%s %-18s = 0x%08X\n', registers{n, 2}, registers{n, 1}, v);
            catch me
                say(opts.Quiet, '  0x%s %-18s : %s\n', registers{n, 2}, registers{n, 1}, me.message);
            end
        end
        if isfield(report(k).Registers, 'FRAME_INFO')
            F = spincam.internal.FrameInfo;
            fi = report(k).Registers.FRAME_INFO;
            say(opts.Quiet, '  FRAME_INFO: GPIO embedding %s, frame counter %s, enabled {%s}\n', ...
                yesNo(F.isSupported(fi, 'GPIO')), yesNo(F.isSupported(fi, 'FrameCounter')), ...
                strjoin(F.enabledFields(fi), ', '));
        end
    catch me
        sys.closeCamera(serial);
        rethrow(me);
    end
    sys.closeCamera(serial);
end
clear releaser
end

function say(quiet, varargin)
if ~quiet
    fprintf(varargin{:});
end
end

function t = describe(s)
if ~s.Readable
    t = sprintf('(%s, not readable)', s.Type);
    return
end
t = sprintf('%s', valueText(s.Value));
if ~isempty(s.Min)
    t = sprintf('%s  [%g .. %g] %s', t, s.Min, s.Max, s.Unit);
end
if ~isempty(s.Entries)
    t = sprintf('%s  {%s}', t, strjoin(s.Entries, '|'));
end
if ~s.Writable
    t = [t '  (read-only now)'];
end
end

function t = valueText(v)
if ischar(v)
    t = v;
elseif isempty(v)
    t = '-';
else
    t = num2str(v);
end
end

function t = yesNo(tf)
if tf
    t = 'supported';
else
    t = 'NOT supported';
end
end
