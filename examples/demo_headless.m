%DEMO_HEADLESS Record from the attached Chameleon3 cameras without the GUI.
%   Wiring: TTL on yellow (OPTO_IN, Line0) / brown (OPTO_GND). Close SpinView first.
%   Files: D:\videoData\<subject>\<session>\<camera>_<subject>_<yyyyMMdd_HHmmss>.avi + .csv

subject = 'mouse01';                                   % change me
session = char(datetime('now', 'Format', 'yyyyMMdd'));

cm = spincam.CameraManager();          % DataRoot 'D:\videoData', DefaultFrameRate 100
cleanup = onCleanup(@() delete(cm));   % always releases the cameras
disp(cm.listCameras());
cm.connect();                          % 100 fps; names topview/sideview by serial order
% cm.setCameraName('24226887', 'topview');   % check which camera is which in the viewer
% cm.setRoi([0 0 1024 900], [], 'Center', true); cm.setProperty('FrameRate', 120);   % faster, cropped

cm.setProperty('ExposureTime', 5000);  % microseconds (must fit in 1/100 s)
cm.setProperty('Gain', 0);
disp(cm.camera('topview').describeProperties());

% Mode A (default): passive TTL logging on Line0
cm.configureSync('passive', 'TtlLine', 'Line0');
% Mode B: cm.configureSync('triggered', 'TriggerType', 'frame', 'TriggerActivation', 'RisingEdge');
% Mode C: cm.configureSync('strobe', 'StrobeLine', 'Line1', 'StrobeEveryN', 1);

cm.Recorder.Format = 'avi-mjpeg-mt';
plan = cm.startRecording(cm.sessionFolder(subject, session), subject);
fprintf('Recording to %s ...\n', plan.Folder);
for k = 1:10
    pause(1);
    stats = cm.getStats();
    disp(stats(:, {'Name', 'Serial', 'FPS', 'FramesReceived', 'FramesMissed', 'QueueDepth', 'LastTTL'}));
end
summary = cm.stopRecording();
disp(struct2table(summary.Cameras, 'AsArray', true));
