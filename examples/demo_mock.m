%DEMO_MOCK Record from two simulated cameras and inspect the logs (no hardware needed).
%   Run from the project root (or with the project root on the path).

cm = spincam.CameraManager('Backend', 'mock', 'NumCameras', 2, 'FrameRate', 60, ...
    'Resolution', [480 640], 'TtlHalfPeriodFrames', 30);
cleanup = onCleanup(@() delete(cm));
cm.DataRoot = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'tests', '_output', 'demo_mock');

cm.connect();                                   % cameras named topview / sideview
cm.configureSync('passive', 'TtlLine', 'Line0');
cm.Recorder.Format = 'avi-mjpeg';

plan = cm.startRecording(cm.sessionFolder('mockmouse', 'demo'), 'mockmouse');
for trial = 1:3
    cm.logEvent('Trial', trial);
    pause(1);
end
summary = cm.stopRecording();
disp(struct2table(summary.Cameras, 'AsArray', true));

T = spincam.io.mergeFrameLogs(summary);         % all cameras, with a Name column
E = spincam.io.readEventLog(summary.EventsFile);

figure('Name', 'spincam mock demo');
top = T(T.Name == "topview", :);
stairs(top.HostTime_s, top.TTL_State, 'LineWidth', 1.5);
hold on
xline(E.HostTime_s(E.Event == "Trial"), '--', 'Trial');
xlabel('Host time (s)');
ylabel('TTL state (Line0)');
title(sprintf('topview (%s): %d frames, %d missed', top.CameraID(1), height(top), sum(top.FramesMissedBefore)));
