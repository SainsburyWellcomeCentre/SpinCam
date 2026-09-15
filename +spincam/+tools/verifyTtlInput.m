function T = verifyTtlInput(seconds, opts)
%VERIFYTTLINPUT Check TTL wiring: stream in passive mode and count edges per line.
%   T = spincam.tools.verifyTtlInput(10) records CSV-only for 10 s on every camera
%   while you pulse the input, then reports rising/falling edges on TtlLine and
%   which lines were ever high (embedded GPIO state, latched per exposure).
%   'FrameRate' defaults to the CameraManager default (100 fps).
arguments
    seconds (1,1) double {mustBePositive} = 10
    opts.Backend (1,:) char = 'spinnaker'
    opts.TtlLine (1,:) char = 'Line0'
    opts.FrameRate (1,1) double {mustBePositive} = 100
    opts.Folder (1,:) char = fullfile(spincam.internal.NativeEngine.projectRoot(), 'tests', '_output', 'verifyTtlInput')
end
cm = spincam.CameraManager('Backend', opts.Backend, 'FrameRate', opts.FrameRate);
closer = onCleanup(@() delete(cm));
cm.connect();
cm.configureSync('passive', 'TtlLine', opts.TtlLine);
cm.Recorder.Format = 'none';
cm.Overwrite = true;
cm.startRecording(opts.Folder, 'ttlcheck');
fprintf('Recording %g s on %d camera(s): apply TTL pulses to %s now...\n', seconds, numel(cm.Cameras), opts.TtlLine);
pause(seconds);
summary = cm.stopRecording();

n = numel(summary.Cameras);
Name = {summary.Cameras.Name}'; Serial = cell(n, 1); Frames = zeros(n, 1); Rising = zeros(n, 1); Falling = zeros(n, 1);
FractionHigh = zeros(n, 1); LinesEverHigh = cell(n, 1); LinesToggling = cell(n, 1);
for k = 1:n
    c = summary.Cameras(k);
    L = spincam.io.readFrameLog(c.CsvFile);
    valid = L.TTL_State >= 0;
    ttl = L.TTL_State(valid);
    Serial{k} = c.Serial;
    Frames(k) = height(L);
    Rising(k) = nnz(diff(ttl) == 1);
    Falling(k) = nnz(diff(ttl) == -1);
    FractionHigh(k) = mean(ttl);
    gpio = L.GPIO_LineStatus(L.GPIO_LineStatus >= 0);
    high = {};
    toggling = {};
    for line = 0:3
        bits = bitand(gpio, 2^line) > 0;
        if any(bits)
            high{end + 1} = sprintf('Line%d', line); %#ok<AGROW>
        end
        if any(bits) && ~all(bits)
            toggling{end + 1} = sprintf('Line%d', line); %#ok<AGROW>
        end
    end
    LinesEverHigh{k} = strjoin(high, ',');
    LinesToggling{k} = strjoin(toggling, ',');
end
T = table(Name, Serial, Frames, Rising, Falling, FractionHigh, LinesEverHigh, LinesToggling);
disp(T);
if all(Rising == 0)
    fprintf(['No rising edges on %s. Check: yellow = OPTO_IN (Line0), brown = OPTO_GND, pulse amplitude ' ...
        '> ~3 V (0-30 V allowed), pulse longer than one frame period.\n'], opts.TtlLine);
end
end
