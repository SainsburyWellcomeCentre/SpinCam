function SpinCamBpodProtocol
%SPINCAMBPODPROTOCOL Example Bpod (Gen2) protocol that records video with spincam.
%   Wiring: Bpod BNC output 1 -> camera yellow (OPTO_IN, Line0) / brown (OPTO_GND).
%   Each trial raises BNC1 for 50 ms; the per-frame TTL_State column marks trial
%   onsets in the video. Cameras keep recording while RunStateMachine blocks MATLAB
%   because acquisition runs on spincam's native threads.
%   Video goes to D:\videoData\<subject>\<Bpod session>\<camera>_<subject>_<datetime>.avi/.csv
global BpodSystem

%% --- camera setup (once per session) ---
subject = BpodSystem.GUIData.SubjectName;
[~, session] = fileparts(BpodSystem.Path.CurrentDataFile);   % e.g. mouse01_Task_20260915_143012
cm = spincam.CameraManager();              % 100 fps, cameras named topview / sideview
cm.connect();
cm.setProperty('ExposureTime', 4000);
cm.configureSync('passive', 'TtlLine', 'Line0');
cm.Recorder.Format = 'avi-mjpeg';          % native encoder: safe while MATLAB is blocked
cm.startRecording(cm.sessionFolder(subject, session), subject);
cleanup = onCleanup(@() stopCameras(cm));  % runs even if the protocol errors or is stopped

MaxTrials = 200;
for currentTrial = 1:MaxTrials
    sma = NewStateMachine();
    sma = AddState(sma, 'Name', 'SyncPulse', 'Timer', 0.05, ...
        'StateChangeConditions', {'Tup', 'ITI'}, ...
        'OutputActions', {'BNC1', 1});
    sma = AddState(sma, 'Name', 'ITI', 'Timer', 2, ...
        'StateChangeConditions', {'Tup', 'exit'}, ...
        'OutputActions', {});
    SendStateMachine(sma);
    cm.logEvent('TrialStart', currentTrial);
    RawEvents = RunStateMachine;
    if ~isempty(fieldnames(RawEvents))
        BpodSystem.Data = AddTrialEvents(BpodSystem.Data, RawEvents);
        SaveBpodSessionData;
    end
    HandlePauseCondition;
    if BpodSystem.Status.BeingUsed == 0
        return
    end
end
end

function stopCameras(cm)
if isvalid(cm)
    if strcmp(cm.State, 'recording')
        cm.stopRecording();
    end
    delete(cm);
end
end
