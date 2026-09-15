function T = readEventLog(csvPath)
%READEVENTLOG Read a <base>_events.csv file (HostTime_s, HostTimestamp_datetime, Event, Value).
arguments
    csvPath {mustBeTextScalar}
end
csvPath = spincam.internal.toWindowsPath(csvPath);
if ~isfile(csvPath)
    error('spincam:io:missingFile', 'File not found: %s', csvPath);
end
opts = delimitedTextImportOptions('Delimiter', ',', 'DataLines', [2 Inf], ...
    'VariableNamingRule', 'preserve');
opts.VariableNames = {'HostTime_s', 'HostTimestamp_datetime', 'Event', 'Value'};
opts.VariableTypes = {'double', 'string', 'string', 'string'};
T = readtable(csvPath, opts);
T.HostTimestamp_datetime = datetime(T.HostTimestamp_datetime, ...
    'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss.SSSSSSxxx', 'TimeZone', 'local', ...
    'Format', 'yyyy-MM-dd HH:mm:ss.SSSSSS');
end
