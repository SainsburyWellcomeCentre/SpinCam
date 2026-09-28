function [T, corrections] = readFrameLog(csvPath, options)
%READFRAMELOG Read a camera's frame log (<camera>_<fileName>_<datetime>.csv) into a table.
%   CameraID and TTL_Source are strings, HostTimestamp_datetime is a datetime in
%   the local time zone, all other columns are double.
%
%   [T, corrections] = spincam.io.readFrameLog(csv) also takes out of HardwareTimestamp_us any
%   spurious step of a whole multiple of 128 s that HostTime_s does not show, and returns how
%   many it took out. The Chameleon3 through Spinnaker now and then stamps a frame, and every
%   frame after it, 128 s late; engine 1.3.0 corrects this as it records (TimestampGuard,
%   summary field TimestampCorrections), so only older logs have the steps. A compact log
%   (no HostTime_s) is left as it is.
%   spincam.io.readFrameLog(csv, 'CorrectTimestampSteps', false) returns the log as written.
arguments
    csvPath {mustBeTextScalar}
    options.CorrectTimestampSteps (1,1) logical = true
end
csvPath = spincam.internal.toWindowsPath(csvPath);
if ~isfile(csvPath)
    error('spincam:io:missingFile', 'File not found: %s', csvPath);
end
opts = delimitedTextImportOptions('Delimiter', ',', 'DataLines', [2 Inf], ...
    'VariableNamesLine', 1, 'VariableNamingRule', 'preserve');
header = strsplit(strtrim(fileread_firstline(csvPath)), ',');
opts.VariableNames = header;
types = repmat({'double'}, 1, numel(header));
types(ismember(header, {'CameraID', 'TTL_Source', 'HostTimestamp_datetime'})) = {'string'};
opts.VariableTypes = types;
T = readtable(csvPath, opts);
T.HostTimestamp_datetime = datetime(T.HostTimestamp_datetime, ...
    'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss.SSSSSSxxx', 'TimeZone', 'local', ...
    'Format', 'yyyy-MM-dd HH:mm:ss.SSSSSS');
corrections = 0;
if options.CorrectTimestampSteps && ismember('HostTime_s', header) && height(T) > 1
    [T.HardwareTimestamp_us, corrections] = removeTimestampSteps(T.HardwareTimestamp_us, T.HostTime_s);
end
end

function [hardwareUs, corrections] = removeTimestampSteps(hardwareUs, hostSeconds)
% The engine's TimestampGuard rule: an interval that exceeds the host interval by a whole
% number of 128 s periods, to within 2 s, is a step, and is taken out of every later frame.
wrapUs = 128e6;
excess = diff(hardwareUs) - diff(hostSeconds) * 1e6;
wraps = round(excess / wrapUs);
isStep = wraps ~= 0 & abs(excess - wraps * wrapUs) < 2e6;
wraps(~isStep) = 0;
hardwareUs = hardwareUs - wrapUs * [0; cumsum(wraps)];
corrections = nnz(isStep);
end

function line = fileread_firstline(path)
fid = fopen(path, 'r');
if fid < 0
    error('spincam:io:openFailed', 'Cannot open %s.', path);
end
closer = onCleanup(@() fclose(fid));
line = fgetl(fid);
if ~ischar(line)
    error('spincam:io:empty', 'File %s is empty.', path);
end
end
