classdef LiveViewer < handle
    %LIVEVIEWER Live multi-camera preview with recording, camera and sync controls.
    %   v = spincam.LiveViewer()                    real cameras (creates a CameraManager)
    %   v = spincam.LiveViewer('Backend', 'mock')   simulated cameras
    %   v = spincam.LiveViewer(cm)                  attach to an existing CameraManager
    %   Additional option: 'Visible' ('on' | 'off').
    %
    %   Layout: a header with Preview / Record and the acquisition state, camera tiles
    %   with per-frame TTL indicators, a statistics table, and three tabs:
    %     Recording  connect cameras, name them (file prefix), choose where to save
    %                (<data root>\<subject>\<session>) and the video format
    %     Camera     frame rate, exposure, gain, black level, gamma (+ auto modes), and crop
    %                (region of interest) with a dashed preview box on the live image
    %     Sync       synchronization mode; only the fields used by that mode are enabled
    %   Pending sync changes are applied automatically when Preview or Record is pressed.
    %   Closing the window stops preview; a CameraManager that was passed in is left
    %   connected (and keeps recording if it was).

    properties (SetAccess = private)
        Manager
        Figure
        OwnsManager logical = false
        LastMessage char = ''
    end

    properties (Access = private)
        Ui = struct()
        Tiles = struct('Serial', {}, 'Title', {}, 'Axes', {}, 'Image', {}, 'Info', {}, 'Ttl', {}, 'Crop', {}, 'Sequence', {})
        Timer = []
        TickCount = 0
        UpdatingControls logical = false
        RecordTimer = []
        FileNameFollowsSubject logical = true
        LastStats = table()
    end

    properties (Constant, Access = private)
        PropertyNames = {'FrameRate', 'ExposureTime', 'Gain', 'BlackLevel', 'Gamma'}
        PropertyLabels = struct('FrameRate', 'Frame rate (Hz)', 'ExposureTime', 'Exposure (µs)', ...
            'Gain', 'Gain (dB)', 'BlackLevel', 'Black level (%)', 'Gamma', 'Gamma')
        AutoProperties = struct('FrameRate', 'FrameRateAuto', 'ExposureTime', 'ExposureAuto', 'Gain', 'GainAuto')
        DisplayMaxWidth = 640
        Palette = struct('Window', [0.93 0.94 0.96], 'Surface', [1 1 1], 'Stage', [0.11 0.12 0.14], ...
            'StageText', [0.92 0.93 0.95], 'StageMuted', [0.62 0.65 0.70], 'Idle', [0.45 0.48 0.53], ...
            'Preview', [0.10 0.52 0.32], 'Recording', [0.78 0.13 0.16], 'Armed', [0.86 0.47 0.04], ...
            'Accent', [0.05 0.40 0.75], 'Muted', [0.50 0.52 0.56], 'Error', [0.78 0.13 0.16], ...
            'TtlHigh', [0.16 0.70 0.35], 'TtlLow', [0.30 0.32 0.36], 'Crop', [1.00 0.78 0.10])
        SyncHelp = struct( ...
            'passive', ['A · Passive TTL logging (default). Cameras free-run at the frame rate. For every frame the ' ...
                'camera latches the state of the TTL line at the end of exposure; it is saved as TTL_State (0/1) ' ...
                'in the CSV. Use it to find trial or stimulus onsets in the video. Wiring: signal → yellow ' ...
                '(Line0), ground → brown. Pulses must last longer than one frame (≥ 15 ms at 100 fps).'], ...
            'triggered', ['B · Hardware trigger. "frame": each TTL edge exposes exactly one frame, so the pulse ' ...
                'rate sets the frame rate. "start": cameras free-run, but recording begins at the first rising ' ...
                'edge. Wiring: trigger → yellow (Line0), ground → brown.'], ...
            'strobe', ['C · Strobe output. The camera drives the strobe line while it exposes (optionally only ' ...
                'every N-th frame) to switch LEDs or tell another device when frames are taken. TTL input ' ...
                'logging continues as in passive mode. Line1 = orange wire (opto output, needs a pull-up ' ...
                'resistor), ground = brown.'])
    end

    methods
        function obj = LiveViewer(varargin)
            args = varargin;
            visible = 'on';
            k = 1;
            while k < numel(args)
                if (ischar(args{k}) || isstring(args{k})) && strcmpi(args{k}, 'Visible')
                    visible = char(args{k + 1});
                    args(k:k + 1) = [];
                else
                    k = k + 1;
                end
            end
            if ~isempty(args) && isa(args{1}, 'spincam.CameraManager')
                obj.Manager = args{1};
            else
                obj.Manager = spincam.CameraManager(args{:});
                obj.OwnsManager = true;
            end
            obj.buildUi(visible);
            if isempty(obj.Manager.Cameras)
                try
                    obj.Manager.connect();
                catch me
                    obj.message(me.message, true);
                end
            end
            obj.syncWidgetsFromManager();
            obj.rebuildCameraList();
            obj.rebuildTiles();
            obj.refreshControls();
            obj.updateState();
            obj.Timer = timer('Name', 'spincam-liveviewer', 'ExecutionMode', 'fixedSpacing', ...
                'Period', 0.05, 'BusyMode', 'drop', 'TimerFcn', @(~, ~) obj.tick());
            start(obj.Timer);
        end

        function delete(obj)
            if ~isempty(obj.Timer) && isvalid(obj.Timer)
                stop(obj.Timer);
                delete(obj.Timer);
            end
            if ~isempty(obj.Manager) && isvalid(obj.Manager)
                if obj.OwnsManager
                    delete(obj.Manager);
                elseif strcmp(obj.Manager.State, 'preview')
                    try
                        obj.Manager.stopPreview();
                    catch
                    end
                end
            end
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                delete(obj.Figure);
            end
        end

        % ------------------------------------------------ programmatic UI actions
        function togglePreview(obj, on)
            obj.Ui.Preview.Value = logical(on);
            obj.onPreview(logical(on));
        end

        function toggleRecording(obj, on)
            obj.Ui.Record.Value = logical(on);
            obj.onRecord(logical(on));
        end

        function setProperty(obj, name, value)
            obj.onProperty(name, value);
        end

        function setAuto(obj, name, on)
            obj.onAuto(name, on);
        end

        function setCrop(obj, roi, opts)
            %SETCROP Fill the crop fields ([x y width height]) and apply them to the "Apply to" camera(s).
            arguments
                obj
                roi (1,4) double
                opts.Center (1,1) logical = false
            end
            fields = {'CropX', 'CropY', 'CropW', 'CropH'};
            for k = 1:4
                c = obj.Ui.(fields{k});
                c.Value = min(max(roi(k), c.Limits(1)), c.Limits(2));
            end
            obj.Ui.CropCenter.Value = opts.Center;
            obj.onCropApply();
        end

        function resetCrop(obj)
            obj.onCropReset();
        end

        function setTarget(obj, target)
            %SETTARGET 'All cameras', or a camera serial/name that property edits apply to.
            target = char(target);
            if strcmpi(target, 'All cameras') || isempty(target)
                obj.Ui.Target.Value = '';
            else
                obj.Ui.Target.Value = obj.Manager.camera(target).Serial;
            end
            obj.refreshControls();
        end

        function setOutput(obj, opts)
            %SETOUTPUT Fill the Recording tab: DataRoot, Subject, Session, FileName, Format, AppendDateTime.
            arguments
                obj
                opts.DataRoot {mustBeTextScalar}
                opts.Subject {mustBeTextScalar}
                opts.Session {mustBeTextScalar}
                opts.FileName {mustBeTextScalar}
                opts.Format {mustBeTextScalar}
                opts.AppendDateTime (1,1) logical
            end
            names = fieldnames(opts);
            for k = 1:numel(names)
                value = opts.(names{k});
                if isstring(value)
                    value = char(value);
                end
                obj.Ui.(names{k}).Value = value;
                if strcmp(names{k}, 'Subject') && ~isfield(opts, 'FileName')
                    obj.onSubjectChanged();
                elseif strcmp(names{k}, 'FileName')
                    obj.FileNameFollowsSubject = false;
                end
            end
            obj.onOutputChanged();
        end

        function folder = outputFolder(obj)
            %OUTPUTFOLDER Folder the next recording is saved to (errors without a subject).
            obj.pushOutputSettings();
            folder = obj.Manager.sessionFolder(obj.Ui.Subject.Value, obj.Ui.Session.Value);
        end

        function setCameraName(obj, serial, name)
            obj.onCameraName(char(serial), char(name));
        end

        function setSync(obj, mode, opts)
            %SETSYNC Set the Sync tab fields and apply them (any SyncController option).
            arguments
                obj
                mode {mustBeTextScalar}
                opts.TtlSource
                opts.TtlLine
                opts.TriggerType
                opts.TriggerActivation
                opts.ExposureMode
                opts.TriggerDelay_us
                opts.StrobeLine
                opts.StrobeSource
                opts.StrobeEveryN
                opts.StrobeDuration_us
                opts.StrobeDelay_us
                opts.StrobeInvert
            end
            obj.Ui.Mode.Value = spincam.SyncController(char(mode)).Mode;
            names = fieldnames(opts);
            for k = 1:numel(names)
                value = opts.(names{k});
                if isstring(value)
                    value = char(value);
                end
                obj.Ui.SyncFields.(names{k}).Control.Value = value;
            end
            obj.updateSyncFields();
            obj.onApplySync();
        end

        function states = syncFieldStates(obj)
            %SYNCFIELDSTATES Struct of logical flags: which Sync tab fields are enabled.
            names = fieldnames(obj.Ui.SyncFields);
            states = struct();
            for k = 1:numel(names)
                states.(names{k}) = strcmp(obj.Ui.SyncFields.(names{k}).Control.Enable, 'on');
            end
        end

        function selectCamera(obj, serial, connected)
            obj.onCameraToggle(char(serial), logical(connected));
        end

        function refresh(obj)
            %REFRESH Run one display/stats update immediately.
            obj.tick(true);
        end

        function images = tileImages(obj)
            images = arrayfun(@(t) t.Image.CData, obj.Tiles, 'UniformOutput', false);
        end
    end

    methods (Access = private)
        % ----------------------------------------------------------------- layout
        function buildUi(obj, visible)
            P = obj.Palette;
            fig = uifigure('Name', 'SpinCam Live Viewer', 'Position', [60 60 1500 900], ...
                'Color', P.Window, 'Visible', visible, 'CloseRequestFcn', @(~, ~) delete(obj));
            obj.Figure = fig;
            root = uigridlayout(fig, [2 2], 'RowHeight', {60, '1x'}, 'ColumnWidth', {'1x', 440}, ...
                'Padding', [10 10 10 10], 'RowSpacing', 10, 'ColumnSpacing', 10, 'BackgroundColor', P.Window);

            % Header: title, state badge, message, preview/record buttons.
            header = uigridlayout(root, [1 5], 'ColumnWidth', {'fit', 190, '1x', 150, 170}, ...
                'Padding', [14 8 10 8], 'ColumnSpacing', 14, 'BackgroundColor', P.Surface);
            header.Layout.Row = 1;
            header.Layout.Column = [1 2];
            uilabel(header, 'Text', 'SpinCam', 'FontSize', 22, 'FontWeight', 'bold', 'FontColor', P.Accent);
            obj.Ui.State = uilabel(header, 'Text', 'IDLE', 'FontSize', 15, 'FontWeight', 'bold', ...
                'FontColor', [1 1 1], 'BackgroundColor', P.Idle, 'HorizontalAlignment', 'center');
            obj.Ui.Message = uilabel(header, 'Text', '', 'WordWrap', 'on', 'FontSize', 12, 'FontColor', P.Muted);
            obj.Ui.Preview = uibutton(header, 'state', 'Text', '▶  Preview', 'FontSize', 15, ...
                'Tooltip', 'Stream all connected cameras without saving.', ...
                'ValueChangedFcn', @(src, ~) obj.onPreview(src.Value));
            obj.Ui.Record = uibutton(header, 'state', 'Text', '●  Record', 'FontSize', 15, 'FontWeight', 'bold', ...
                'FontColor', [1 1 1], 'BackgroundColor', P.Recording, ...
                'Tooltip', 'Save video + per-frame CSV for all connected cameras (Recording tab settings).', ...
                'ValueChangedFcn', @(src, ~) obj.onRecord(src.Value));

            % Left: camera tiles and statistics.
            left = uigridlayout(root, [2 1], 'RowHeight', {'1x', 118}, 'Padding', [0 0 0 0], ...
                'RowSpacing', 10, 'BackgroundColor', P.Window);
            left.Layout.Row = 2;
            left.Layout.Column = 1;
            obj.Ui.ImageGrid = uigridlayout(left, [1 1], 'Padding', [8 8 8 8], 'RowSpacing', 8, ...
                'ColumnSpacing', 8, 'BackgroundColor', P.Stage);
            obj.Ui.Stats = uitable(left, 'RowName', {}, 'FontSize', 12);

            % Right: tabs.
            tabs = uitabgroup(root);
            tabs.Layout.Row = 2;
            tabs.Layout.Column = 2;
            obj.buildRecordingTab(uitab(tabs, 'Title', 'Recording', 'BackgroundColor', P.Surface));
            obj.buildCameraTab(uitab(tabs, 'Title', 'Camera', 'BackgroundColor', P.Surface));
            obj.buildSyncTab(uitab(tabs, 'Title', 'Sync', 'BackgroundColor', P.Surface));
        end

        function buildRecordingTab(obj, tab)
            P = obj.Palette;
            g = uigridlayout(tab, [2 1], 'RowHeight', {'fit', 'fit'}, 'Scrollable', 'on', ...
                'Padding', [10 10 10 10], 'RowSpacing', 12, 'BackgroundColor', P.Surface);

            obj.Ui.CameraPanel = sectionPanel(g, 'Cameras', P);
            obj.Ui.CameraSerials = {};
            obj.Ui.CameraBoxes = {};
            obj.Ui.NameFields = {};

            p = sectionPanel(g, 'Where to save', P);
            f = uigridlayout(p, [8 3], 'RowHeight', repmat({'fit'}, 1, 8), 'ColumnWidth', {92, '1x', 72}, ...
                'BackgroundColor', P.Surface);
            addLabel(f, 'Data root', 'Base folder for all recordings.');
            obj.Ui.DataRoot = uieditfield(f, 'text', 'Value', obj.Manager.DataRoot, ...
                'Tooltip', 'Recordings go to <data root>\<subject>\<session>.', ...
                'ValueChangedFcn', @(~, ~) obj.onOutputChanged());
            uibutton(f, 'Text', 'Browse…', 'ButtonPushedFcn', @(~, ~) obj.onBrowse());
            addLabel(f, 'Subject', 'Animal / subject ID; becomes a sub-folder. Required.');
            obj.Ui.Subject = uieditfield(f, 'text', 'Placeholder', 'e.g. mouse01', ...
                'Tooltip', 'Animal / subject ID; becomes a sub-folder. Required.', ...
                'ValueChangedFcn', @(~, ~) obj.onSubjectChanged());
            obj.Ui.Subject.Layout.Column = [2 3];
            addLabel(f, 'Session', 'Session name; becomes a sub-folder of the subject folder.');
            obj.Ui.Session = uieditfield(f, 'text', 'Value', char(datetime('now', 'Format', 'yyyyMMdd')), ...
                'Tooltip', 'Session name; becomes a sub-folder of the subject folder (default: today).', ...
                'ValueChangedFcn', @(~, ~) obj.onOutputChanged());
            obj.Ui.Session.Layout.Column = [2 3];
            addLabel(f, 'File name', 'Middle part of every file name: <camera>_<file name>_<date_time>.');
            obj.Ui.FileName = uieditfield(f, 'text', 'Placeholder', 'optional (defaults to subject)', ...
                'Tooltip', 'Middle part of every file name: <camera>_<file name>_<date_time>.', ...
                'ValueChangedFcn', @(~, ~) obj.onFileNameChanged());
            obj.Ui.FileName.Layout.Column = [2 3];
            obj.Ui.AppendDateTime = uicheckbox(f, 'Text', 'Append _date_time (recording start) to file names', ...
                'Value', obj.Manager.AppendDateTime, 'ValueChangedFcn', @(~, ~) obj.onOutputChanged());
            obj.Ui.AppendDateTime.Layout.Column = [2 3];
            addLabel(f, 'Format', 'Video container / codec.');
            obj.Ui.Format = uidropdown(f, 'Items', formatLabels(), 'ItemsData', spincam.VideoRecorder.Formats, ...
                'Value', obj.Manager.Recorder.Format, 'ValueChangedFcn', @(~, ~) obj.onOutputChanged(), ...
                'Tooltip', ['avi-mjpeg-mt: compact, encoded on several cores, full frame up to 150 fps. avi-mjpeg: ' ...
                'SpinVideo, ≤ ~100 fps per camera. raw: lossless, any frame rate (convert with ' ...
                'spincam.io.rawToAvi). matlab-*: not safe while Bpod blocks MATLAB.']);
            obj.Ui.Format.Layout.Column = [2 3];
            label = addLabel(f, 'Files', 'What the next recording will create.');
            label.VerticalAlignment = 'top';
            obj.Ui.OutputPreview = uilabel(f, 'Text', '', 'WordWrap', 'on', 'FontName', 'Consolas', ...
                'FontSize', 11, 'FontColor', P.Muted, 'VerticalAlignment', 'top');
            obj.Ui.OutputPreview.Layout.Column = [2 3];
        end

        function buildCameraTab(obj, tab)
            P = obj.Palette;
            names = obj.PropertyNames;
            g = uigridlayout(tab, [3 1], 'RowHeight', {'fit', 'fit', 'fit'}, 'Scrollable', 'on', ...
                'Padding', [10 10 10 10], 'RowSpacing', 12, 'BackgroundColor', P.Surface);
            p = sectionPanel(g, 'Camera properties', P);
            f = uigridlayout(p, [numel(names) + 1, 4], 'RowHeight', repmat({'fit'}, 1, numel(names) + 1), ...
                'ColumnWidth', {100, '1x', 80, 48}, 'BackgroundColor', P.Surface);
            addLabel(f, 'Apply to', 'Cameras affected by the controls below.');
            obj.Ui.Target = uidropdown(f, 'Items', {'All cameras'}, 'ItemsData', {''}, ...
                'ValueChangedFcn', @(~, ~) obj.refreshControls());
            obj.Ui.Target.Layout.Column = [2 4];
            for k = 1:numel(names)
                name = names{k};
                addLabel(f, obj.PropertyLabels.(name), '');
                slider = uislider(f, 'MajorTicks', [], 'MinorTicks', [], ...
                    'ValueChangedFcn', @(src, ~) obj.onProperty(name, src.Value));
                spinner = uispinner(f, 'ValueDisplayFormat', '%.4g', ...
                    'ValueChangedFcn', @(src, ~) obj.onProperty(name, src.Value));
                auto = uicheckbox(f, 'Text', 'Auto', 'ValueChangedFcn', @(src, ~) obj.onAuto(name, src.Value));
                if ~isfield(obj.AutoProperties, name)
                    auto.Visible = 'off';
                end
                obj.Ui.Props.(name) = struct('Slider', slider, 'Spinner', spinner, 'Auto', auto);
            end
            p = sectionPanel(g, 'Crop (region of interest)', P);
            f = uigridlayout(p, [5 4], 'RowHeight', repmat({'fit'}, 1, 5), 'ColumnWidth', {50, '1x', 50, '1x'}, ...
                'BackgroundColor', P.Surface);
            addLabel(f, 'X', 'Left edge of the crop in pixels from the left of the sensor (multiple of 8).');
            obj.Ui.CropX = cropSpinner(f, 8, @() obj.updateCropOverlay());
            addLabel(f, 'Y', 'Top edge of the crop in pixels from the top of the sensor (even).');
            obj.Ui.CropY = cropSpinner(f, 2, @() obj.updateCropOverlay());
            addLabel(f, 'Width', 'Crop width in pixels (rounded down to a multiple of 16).');
            obj.Ui.CropW = cropSpinner(f, 16, @() obj.updateCropOverlay());
            addLabel(f, 'Height', 'Crop height in pixels (rounded down to an even number).');
            obj.Ui.CropH = cropSpinner(f, 2, @() obj.updateCropOverlay());
            obj.Ui.CropCenter = uicheckbox(f, 'Text', 'Centre on the sensor (ignore X and Y)', ...
                'ValueChangedFcn', @(~, ~) obj.updateCropOverlay());
            obj.Ui.CropCenter.Layout.Row = 3;
            obj.Ui.CropCenter.Layout.Column = [1 4];
            obj.Ui.CropApply = uibutton(f, 'Text', 'Apply crop', 'FontWeight', 'bold', ...
                'Tooltip', 'Crop the "Apply to" camera(s). Preview restarts; not possible while recording.', ...
                'ButtonPushedFcn', @(~, ~) obj.onCropApply());
            obj.Ui.CropApply.Layout.Row = 4;
            obj.Ui.CropApply.Layout.Column = [1 2];
            obj.Ui.CropReset = uibutton(f, 'Text', 'Full frame', 'Tooltip', 'Remove the crop.', ...
                'ButtonPushedFcn', @(~, ~) obj.onCropReset());
            obj.Ui.CropReset.Layout.Row = 4;
            obj.Ui.CropReset.Layout.Column = [3 4];
            obj.Ui.CropStatus = uilabel(f, 'Text', '', 'WordWrap', 'on', 'FontSize', 11, 'FontColor', P.Muted);
            obj.Ui.CropStatus.Layout.Row = 5;
            obj.Ui.CropStatus.Layout.Column = [1 4];

            note = uilabel(g, 'WordWrap', 'on', 'FontSize', 11, 'FontColor', P.Muted, 'Text', sprintf([ ...
                'Cameras are set to %s when they connect. At full frame, MJPEG video keeps up with about ' ...
                '100 fps per camera; crop to record faster (encoding speed scales with the cropped area, ' ...
                'the Chameleon3 itself tops out at 150 fps). Two full-frame cameras sharing one USB 3.0 ' ...
                'controller lose frames above ~120 fps. Manual exposure must fit in one frame period. ' ...
                'Gamma is not available on Chameleon3 firmware 1.13.'], frameRateText(obj.Manager.DefaultFrameRate)));
            note.Layout.Row = 3;
        end

        function buildSyncTab(obj, tab)
            P = obj.Palette;
            g = uigridlayout(tab, [6 1], 'RowHeight', {'fit', 'fit', 'fit', 'fit', 'fit', 'fit'}, ...
                'Scrollable', 'on', 'Padding', [10 10 10 10], 'RowSpacing', 12, 'BackgroundColor', P.Surface);

            p = sectionPanel(g, 'Mode', P);
            f = uigridlayout(p, [2 1], 'RowHeight', {'fit', 'fit'}, 'BackgroundColor', P.Surface);
            obj.Ui.Mode = uidropdown(f, 'Items', {'A · Passive TTL logging (default)', 'B · Hardware trigger', ...
                'C · Strobe output'}, 'ItemsData', {'passive', 'triggered', 'strobe'}, 'FontWeight', 'bold', ...
                'ValueChangedFcn', @(~, ~) obj.updateSyncFields());
            obj.Ui.SyncHelp = uilabel(f, 'Text', '', 'WordWrap', 'on', 'FontSize', 11, 'FontColor', P.Muted);

            fields = struct();
            obj.Ui.InputPanel = sectionPanel(g, 'TTL input · logged in every mode', P);
            f = syncGrid(obj.Ui.InputPanel, 2, P);
            fields.TtlSource = syncField(f, 'TTL source', uidropdown(f, 'Items', ...
                {'embedded (camera-latched)', 'polled (host)', 'none (do not log)'}, ...
                'ItemsData', {'embedded', 'polled', 'none'}), ['embedded: the camera stores the input state in ' ...
                'each frame at the end of exposure (exact; default). polled: the host reads the line status ' ...
                '(~1 ms resolution, fallback). none: TTL_State is -1.']);
            fields.TtlLine = syncField(f, 'TTL line', uidropdown(f, 'Items', ...
                {'Line0 · yellow (opto input)', 'Line2 · purple', 'Line3 · green'}, ...
                'ItemsData', {'Line0', 'Line2', 'Line3'}), ['Input whose state is logged (and, in trigger mode, ' ...
                'the trigger input). Line0 = yellow wire with brown as ground.']);

            obj.Ui.TriggerPanel = sectionPanel(g, 'Trigger', P);
            f = syncGrid(obj.Ui.TriggerPanel, 4, P);
            fields.TriggerType = syncField(f, 'Trigger type', uidropdown(f, 'Items', ...
                {'frame · one frame per edge', 'start · begin recording at first edge'}, ...
                'ItemsData', {'frame', 'start'}), ['frame: TriggerMode=On, each edge exposes one frame. start: ' ...
                'free-run; the recording is armed and starts at the first rising edge on the TTL line.']);
            fields.TriggerActivation = syncField(f, 'Activation', uidropdown(f, 'Items', {'RisingEdge', 'FallingEdge'}), ...
                'Edge that triggers a frame (frame type only).');
            fields.ExposureMode = syncField(f, 'Exposure mode', uidropdown(f, 'Items', ...
                {'Timed · use Exposure setting', 'TriggerWidth · exposure = pulse width'}, ...
                'ItemsData', {'Timed', 'TriggerWidth'}), ['Timed: exposure uses the Camera tab exposure. ' ...
                'TriggerWidth: exposure lasts as long as the trigger pulse is active.']);
            fields.TriggerDelay_us = syncField(f, 'Delay (µs)', uispinner(f, 'Limits', [0 1e6], 'Step', 100, ...
                'Value', 0), 'Delay from the trigger edge to the start of exposure.');

            obj.Ui.StrobePanel = sectionPanel(g, 'Strobe output', P);
            f = syncGrid(obj.Ui.StrobePanel, 6, P);
            fields.StrobeLine = syncField(f, 'Strobe line', uidropdown(f, 'Items', ...
                {'Line1 · orange (opto output)', 'Line2 · purple', 'Line3 · green'}, ...
                'ItemsData', {'Line1', 'Line2', 'Line3'}), ['Output line. Line1 is opto-isolated and needs a pull-up ' ...
                'resistor; Line2/Line3 are switched to outputs (never connect a voltage source to them).']);
            fields.StrobeSource = syncField(f, 'Signal', uidropdown(f, 'Items', ...
                {'ExposureActive', 'ExternalTriggerActive'}), ['ExposureActive: high while the sensor exposes. ' ...
                'ExternalTriggerActive: high while the trigger input is active.']);
            fields.StrobeEveryN = syncField(f, 'Every N frames', uispinner(f, 'Limits', [1 16], 'Step', 1, ...
                'RoundFractionalValues', 'on', 'Value', 1), 'Pulse only on every N-th frame (1–16, camera hardware pattern).');
            fields.StrobeDuration_us = syncField(f, 'Duration (µs)', uispinner(f, 'Limits', [0 65535], 'Step', 100, ...
                'Value', 0), 'Pulse length; 0 = as long as the exposure.');
            fields.StrobeDelay_us = syncField(f, 'Delay (µs)', uispinner(f, 'Limits', [0 65535], 'Step', 100, ...
                'Value', 0), 'Delay after the start of exposure.');
            fields.StrobeInvert = syncField(f, 'Invert', uicheckbox(f, 'Text', 'active low'), ...
                'Invert the output polarity.');
            names = fieldnames(fields);
            for k = 1:numel(names)
                fields.(names{k}).Control.ValueChangedFcn = @(~, ~) obj.updateSyncFields();
            end
            obj.Ui.SyncFields = fields;

            f = uigridlayout(g, [1 2], 'ColumnWidth', {130, '1x'}, 'Padding', [0 0 0 0], 'BackgroundColor', P.Surface);
            obj.Ui.ApplySync = uibutton(f, 'Text', 'Apply sync', 'FontWeight', 'bold', ...
                'Tooltip', 'Write the sync settings to the cameras (also done automatically on Preview/Record).', ...
                'ButtonPushedFcn', @(~, ~) obj.onApplySync());
            obj.Ui.SyncStatus = uilabel(f, 'Text', '', 'WordWrap', 'on', 'FontSize', 11);
        end

        function rebuildCameraList(obj)
            P = obj.Palette;
            delete(obj.Ui.CameraPanel.Children);
            obj.Ui.CameraSerials = {};
            obj.Ui.CameraBoxes = {};
            obj.Ui.NameFields = {};
            try
                info = obj.Manager.listCameras();
            catch me
                obj.message(me.message, true);
                return
            end
            n = height(info);
            g = uigridlayout(obj.Ui.CameraPanel, [n + 1, 2], 'RowHeight', repmat({'fit'}, 1, n + 1), ...
                'ColumnWidth', {'1x', 130}, 'BackgroundColor', P.Surface);
            uilabel(g, 'Text', 'Connect', 'FontColor', P.Muted, 'FontSize', 11);
            uilabel(g, 'Text', 'Name (file prefix)', 'FontColor', P.Muted, 'FontSize', 11, ...
                'Tooltip', 'Prepended to this camera''s video and CSV file names.');
            if n == 0
                label = uilabel(g, 'Text', 'No cameras found (close SpinView?)');
                label.Layout.Column = [1 2];
                return
            end
            for k = 1:n
                serial = info.Serial{k};
                obj.Ui.CameraSerials{k} = serial;
                model =regexprep(info.Model{k}, '^.*\s(\S+)$', '$1');
                obj.Ui.CameraBoxes{k} = uicheckbox(g, 'Text', sprintf('%s  ·  %s', serial, model), ...
                    'Value', info.Connected(k), 'ValueChangedFcn', @(src, ~) obj.onCameraToggle(serial, src.Value));
                obj.Ui.NameFields{k} = uieditfield(g, 'text', 'Value', info.Name{k}, ...
                    'Placeholder', 'connect first', 'Enable', onOff(info.Connected(k)), ...
                    'Tooltip', 'e.g. topview / sideview', ...
                    'ValueChangedFcn', @(src, ~) obj.onCameraName(serial, src.Value));
            end
        end

        function rebuildTiles(obj)
            P = obj.Palette;
            delete(obj.Ui.ImageGrid.Children);
            obj.Tiles = obj.Tiles([]);
            cams = obj.Manager.Cameras;
            n = numel(cams);
            serials = {cams.Serial};
            obj.Ui.Target.Items = [{'All cameras'}, arrayfun(@(c) sprintf('%s (%s)', c.Name, c.Serial), cams, ...
                'UniformOutput', false)];
            obj.Ui.Target.ItemsData = [{''}, serials];
            if n == 0
                obj.Ui.ImageGrid.RowHeight = {'1x'};
                obj.Ui.ImageGrid.ColumnWidth = {'1x'};
                uilabel(obj.Ui.ImageGrid, 'Text', 'No cameras connected', 'HorizontalAlignment', 'center', ...
                    'FontSize', 16, 'FontColor', P.StageMuted);
                return
            end
            cols = ceil(sqrt(n));
            rows = ceil(n / cols);
            obj.Ui.ImageGrid.RowHeight = repmat({'1x'}, 1, rows);
            obj.Ui.ImageGrid.ColumnWidth = repmat({'1x'}, 1, cols);
            for k = 1:n
                tile = uigridlayout(obj.Ui.ImageGrid, [3 1], 'RowHeight', {24, '1x', 24}, ...
                    'Padding', [6 4 6 4], 'RowSpacing', 2, 'BackgroundColor', P.Stage);
                title = uilabel(tile, 'Text', tileTitle(cams(k)), 'FontSize', 14, 'FontWeight', 'bold', ...
                    'FontColor', P.StageText);
                ax = uiaxes(tile, 'Color', [0 0 0], 'XColor', 'none', 'YColor', 'none', ...
                    'XTick', [], 'YTick', [], 'Box', 'off');
                if isprop(ax, 'BackgroundColor')
                    ax.BackgroundColor = P.Stage;
                end
                disableDefaultInteractivity(ax);
                ax.Toolbar.Visible = 'off';
                ax.Colormap = gray(256);
                img = image(ax, zeros(2, 2, 'uint8'), 'CDataMapping', 'scaled');
                ax.CLim = [0 255];
                ax.YDir = 'reverse';
                axis(ax, 'image');
                crop = rectangle(ax, 'Position', [0.5 0.5 1 1], 'EdgeColor', P.Crop, 'LineWidth', 2, ...
                    'LineStyle', '--', 'Visible', 'off', 'PickableParts', 'none');
                footer = uigridlayout(tile, [1 2], 'ColumnWidth', {'1x', 70}, 'Padding', [0 0 0 0], ...
                    'BackgroundColor', P.Stage);
                info = uilabel(footer, 'Text', 'not streaming', 'FontName', 'Consolas', 'FontSize', 12, ...
                    'FontColor', P.StageMuted);
                ttl = uilabel(footer, 'Text', 'TTL –', 'FontWeight', 'bold', 'FontColor', [1 1 1], ...
                    'BackgroundColor', P.TtlLow, 'HorizontalAlignment', 'center', ...
                    'Tooltip', 'State of the TTL line in the latest frame');
                obj.Tiles(k) = struct('Serial', serials{k}, 'Title', title, 'Axes', ax, 'Image', img, ...
                    'Info', info, 'Ttl', ttl, 'Crop', crop, 'Sequence', -1);
            end
        end

        % ------------------------------------------------------------ callbacks
        function tick(obj, force)
            if nargin < 2
                force = false;
            end
            if ~isvalid(obj) || isempty(obj.Figure) || ~isvalid(obj.Figure)
                return
            end
            obj.TickCount = obj.TickCount + 1;
            cm = obj.Manager;
            try
                if ~strcmp(cm.State, 'idle')
                    for k = 1:numel(obj.Tiles)
                        obj.updateTile(k);
                    end
                end
                if force || mod(obj.TickCount, 10) == 0
                    obj.updateStats();
                    obj.updateState();
                end
            catch me
                obj.message(['Display update failed: ' me.message], false);
            end
            drawnow limitrate
        end

        function updateTile(obj, k)
            P = obj.Palette;
            t = obj.Tiles(k);
            dev = obj.Manager.camera(t.Serial);
            if isempty(dev.Stream) || ~dev.isStreaming()
                return
            end
            [img, meta] = dev.latestFrame();
            if isempty(img) || meta.Sequence == t.Sequence
                return
            end
            step = max(1, ceil(size(img, 2) / obj.DisplayMaxWidth));
            shown = img(1:step:end, 1:step:end);
            if ~isequal(size(t.Image.CData), size(shown))
                t.Axes.XLim = [0.5, size(shown, 2) + 0.5];
                t.Axes.YLim = [0.5, size(shown, 1) + 0.5];
            end
            t.Image.CData = shown;
            fps = NaN;
            missed = 0;
            S = obj.LastStats;
            if ~isempty(S)
                row = find(strcmp(S.Serial, t.Serial), 1);
                if ~isempty(row)
                    fps = S.FPS(row);
                    missed = S.FramesMissed(row);
                end
            end
            t.Info.Text = sprintf('frame %-8d %6.1f fps   missed %d', meta.FrameId, fps, missed);
            if meta.TTL >= 0
                t.Ttl.Text = sprintf('TTL %d', meta.TTL);
                t.Ttl.BackgroundColor = P.TtlLow;
                if meta.TTL == 1
                    t.Ttl.BackgroundColor = P.TtlHigh;
                end
            else
                t.Ttl.Text = 'TTL –';
                t.Ttl.BackgroundColor = P.TtlLow;
            end
            obj.Tiles(k).Sequence = meta.Sequence;
        end

        function updateStats(obj)
            cm = obj.Manager;
            if isempty(cm.Cameras) || strcmp(cm.State, 'idle')
                return
            end
            S = cm.getStats();
            obj.LastStats = S;
            TTL = strings(height(S), 1);
            TTL(S.LastTTL == 1) = "HIGH";
            TTL(S.LastTTL == 0) = "low";
            TTL(~(S.LastTTL >= 0)) = "–";
            obj.Ui.Stats.Data = table(string(S.Name), string(S.Serial), compose("%.1f", S.FPS), S.FramesReceived, ...
                S.FramesMissed, S.FramesWritten, S.WriterDrops, S.QueueDepth, TTL, 'VariableNames', ...
                {'Camera', 'Serial', 'FPS', 'Received', 'Missed', 'Written', 'Writer drops', 'Queue', 'TTL'});
            faulted = S.Faulted | ~cellfun(@isempty, S.LastError);
            if any(faulted)
                obj.message(strjoin(S.LastError(faulted), ' | '), false);
            end
        end

        function updateState(obj)
            P = obj.Palette;
            cm = obj.Manager;
            state = cm.State;
            recording = strcmp(state, 'recording');
            switch state
                case 'recording'
                    label = '●  REC';
                    color = P.Recording;
                    if ~isempty(obj.RecordTimer)
                        elapsed = toc(obj.RecordTimer);
                        label = sprintf('●  REC  %02d:%02d', floor(elapsed / 60), floor(mod(elapsed, 60)));
                    end
                    try
                        if any(cm.getStats().Armed)
                            label = 'ARMED · waiting for TTL';
                            color = P.Armed;
                        end
                    catch
                    end
                case 'preview'
                    label = 'PREVIEW';
                    color = P.Preview;
                otherwise
                    label = 'IDLE';
                    color = P.Idle;
            end
            obj.Ui.State.Text = label;
            obj.Ui.State.BackgroundColor = color;
            obj.Ui.Preview.Value = ~strcmp(state, 'idle');
            obj.Ui.Record.Value = recording;
            if recording
                obj.Ui.Record.Text = '■  Stop recording';
            else
                obj.Ui.Record.Text = '●  Record';
            end
            if strcmp(state, 'idle')
                obj.Ui.Preview.Text = '▶  Preview';
            else
                obj.Ui.Preview.Text = '■  Stop preview';
            end
            unlocked = onOff(~recording);
            obj.Ui.Preview.Enable = unlocked;
            obj.Ui.Record.Enable = onOff(~isempty(cm.Cameras));
            set([obj.Ui.DataRoot, obj.Ui.Subject, obj.Ui.Session, obj.Ui.FileName, obj.Ui.AppendDateTime, ...
                obj.Ui.Format], 'Enable', unlocked);
            set(obj.cropControls(), 'Enable', onOff(~recording && ~isempty(cm.Cameras)));
            connected = ismember(obj.Ui.CameraSerials, {cm.Cameras.Serial});
            for k = 1:numel(obj.Ui.CameraBoxes)
                obj.Ui.CameraBoxes{k}.Enable = unlocked;
                obj.Ui.NameFields{k}.Enable = onOff(~recording && connected(k));
            end
            obj.updateSyncFields();
            obj.updateOutputPreview();
        end

        function onPreview(obj, value)
            try
                if value
                    obj.applySyncIfPending();
                    obj.Manager.startPreview();
                else
                    obj.Manager.stopPreview();
                end
            catch me
                obj.message(me.message, true);
            end
            obj.updateState();
        end

        function onRecord(obj, value)
            cm = obj.Manager;
            try
                if value
                    folder = obj.outputFolder();
                    obj.applySyncIfPending();
                    plan = cm.startRecording(folder, obj.Ui.FileName.Value);
                    obj.RecordTimer = tic;
                    obj.message(sprintf('Recording to %s  (%s)', plan.Folder, ...
                        strjoin({plan.Cameras.Name}, ', ')), false);
                else
                    s = cm.stopRecording();
                    obj.RecordTimer = [];
                    parts = arrayfun(@(c) sprintf('%s: %d frames, %d missed, %d writer drops', ...
                        c.Name, c.FramesLogged, c.FramesMissed, c.WriterDrops), s.Cameras, 'UniformOutput', false);
                    obj.message(sprintf('Saved %.1f s to %s. %s', s.Duration_s, s.Folder, strjoin(parts, '; ')), false);
                end
            catch me
                if strcmp(me.identifier, 'spincam:manager:noSubject')
                    obj.message('Enter a subject name on the Recording tab before recording.', true);
                else
                    obj.message(me.message, true);
                end
            end
            obj.updateState();
        end

        function onProperty(obj, name, value)
            if obj.UpdatingControls
                return
            end
            try
                [~, warnId] = lastwarn('');
                obj.Manager.setProperty(name, value, obj.targetIds());
                [warnMsg, warnId] = lastwarn();
                if strcmp(warnId, 'spincam:property:clamped')
                    obj.message(warnMsg, false);
                end
            catch me
                obj.message(me.message, true);
            end
            obj.refreshControls();
        end

        function onAuto(obj, name, on)
            if obj.UpdatingControls
                return
            end
            mode = 'Off';
            if on
                mode = 'Continuous';
            end
            try
                obj.Manager.setProperty(obj.AutoProperties.(name), mode, obj.targetIds());
            catch me
                obj.message(me.message, true);
            end
            obj.refreshControls();
        end

        function onApplySync(obj)
            try
                args = obj.syncArgs();
                obj.Manager.configureSync(obj.Ui.Mode.Value, args{:});
                obj.message(['Sync applied: ' obj.Manager.Sync.describe()], false);
            catch me
                obj.message(me.message, true);
            end
            obj.updateState();
        end

        function applySyncIfPending(obj)
            if obj.syncPending()
                args = obj.syncArgs();
                obj.Manager.configureSync(obj.Ui.Mode.Value, args{:});
            end
        end

        function onBrowse(obj)
            folder = uigetdir(obj.Ui.DataRoot.Value, 'Data root folder');
            if ischar(folder)
                obj.Ui.DataRoot.Value = folder;
                obj.onOutputChanged();
            end
            figure(obj.Figure);
        end

        function onSubjectChanged(obj)
            if obj.FileNameFollowsSubject
                obj.Ui.FileName.Value = spincam.CameraManager.cleanName(obj.Ui.Subject.Value);
            end
            obj.onOutputChanged();
        end

        function onFileNameChanged(obj)
            value = obj.Ui.FileName.Value;
            obj.FileNameFollowsSubject = isempty(value) || ...
                strcmp(value, spincam.CameraManager.cleanName(obj.Ui.Subject.Value));
            obj.onOutputChanged();
        end

        function onOutputChanged(obj)
            try
                obj.pushOutputSettings();
            catch me
                obj.message(me.message, true);
            end
            obj.updateOutputPreview();
        end

        function onCameraName(obj, serial, name)
            try
                obj.Manager.setCameraName(serial, name);
            catch me
                obj.message(me.message, true);
            end
            obj.rebuildCameraList();
            for k = 1:numel(obj.Tiles)
                obj.Tiles(k).Title.Text = tileTitle(obj.Manager.camera(obj.Tiles(k).Serial));
            end
            obj.Ui.Target.Items = [{'All cameras'}, arrayfun(@(c) sprintf('%s (%s)', c.Name, c.Serial), ...
                obj.Manager.Cameras, 'UniformOutput', false)];
            obj.updateState();
        end

        function onCameraToggle(obj, serial, connected)
            try
                if connected
                    obj.Manager.connect({serial});
                else
                    obj.Manager.disconnect({serial});
                end
            catch me
                obj.message(me.message, true);
            end
            obj.rebuildCameraList();
            obj.rebuildTiles();
            obj.refreshControls();
            obj.updateState();
        end

        % ------------------------------------------------------------------- crop
        function onCropApply(obj)
            try
                lastwarn('');
                actual = obj.Manager.setRoi(obj.cropFieldsRoi(), obj.targetIds(), 'Center', obj.Ui.CropCenter.Value);
                [warnMsg, warnId] = lastwarn();
                rows = arrayfun(@(k) sprintf('%d×%d at (%d, %d)', actual(k, 3), actual(k, 4), actual(k, 1), ...
                    actual(k, 2)), 1:size(actual, 1), 'UniformOutput', false);
                text = ['Crop applied: ' strjoin(rows, '; ')];
                if strcmp(warnId, 'spincam:roi:adjusted')
                    text = [text '. ' warnMsg];
                end
                obj.message(text, false);
            catch me
                obj.message(me.message, true);
            end
            obj.refreshControls();
            obj.updateState();
        end

        function onCropReset(obj)
            try
                obj.Manager.resetRoi(obj.targetIds());
                obj.message('Full frame restored.', false);
            catch me
                obj.message(me.message, true);
            end
            obj.refreshControls();
            obj.updateState();
        end

        function refreshCrop(obj)
            %REFRESHCROP Show the crop of the first "Apply to" camera in the fields.
            ui = obj.Ui;
            cams = obj.Manager.Cameras;
            if isempty(cams)
                set(obj.cropControls(), 'Enable', 'off');
                ui.CropStatus.Text = 'Connect a camera to crop.';
                return
            end
            ids = obj.targetIds();
            if isempty(ids)
                dev = cams(1);
            else
                dev = obj.Manager.camera(ids{1});
            end
            try
                roi = dev.getRoi();
                full = dev.sensorSize();
            catch me
                ui.CropStatus.Text = me.message;
                return
            end
            ui.CropX.Limits = [0 max(1, full(1) - 1)];
            ui.CropY.Limits = [0 max(1, full(2) - 1)];
            ui.CropW.Limits = [1 full(1)];
            ui.CropH.Limits = [1 full(2)];
            ui.CropX.Value = roi(1);
            ui.CropY.Value = roi(2);
            ui.CropW.Value = roi(3);
            ui.CropH.Value = roi(4);
            if isequal(roi, [0 0 full])
                state = sprintf('%s: full frame %d × %d.', dev.Name, full(1), full(2));
            else
                state = sprintf('%s: cropped to %d × %d at (%d, %d) of %d × %d.', dev.Name, roi(3), roi(4), ...
                    roi(1), roi(2), full(1), full(2));
            end
            capacity = spincam.VideoRecorder.MeasuredCapacity.avi_mjpeg * 1280 * 1024 / (roi(3) * roi(4));
            ui.CropStatus.Text = sprintf(['%s MJPEG video keeps up with about %.0f fps at this size. Edit the ' ...
                'numbers to preview a new crop as a dashed box on the full-frame image.'], state, capacity);
            set(obj.cropControls(), 'Enable', onOff(~strcmp(obj.Manager.State, 'recording')));
            obj.updateCropOverlay();
        end

        function updateCropOverlay(obj)
            %UPDATECROPOVERLAY Dashed box on full-frame tiles showing the crop in the fields.
            cm = obj.Manager;
            ids = obj.targetIds();
            roi = obj.cropFieldsRoi();
            for k = 1:numel(obj.Tiles)
                t = obj.Tiles(k);
                show = false;
                if isempty(ids) || any(strcmp(ids, t.Serial))
                    try
                        dev = cm.camera(t.Serial);
                        full = dev.sensorSize();
                        if isequal(dev.getRoi(), [0 0 full])
                            r = roi;
                            if obj.Ui.CropCenter.Value
                                r(1:2) = floor((full - r(3:4)) / 2);
                            end
                            step = max(1, ceil(full(1) / obj.DisplayMaxWidth));
                            t.Crop.Position = [r(1) / step + 0.5, r(2) / step + 0.5, r(3) / step, r(4) / step];
                            show = ~isequal(r, [0 0 full]);
                        end
                    catch
                    end
                end
                t.Crop.Visible = onOff(show);
            end
        end

        function roi = cropFieldsRoi(obj)
            roi = [obj.Ui.CropX.Value, obj.Ui.CropY.Value, obj.Ui.CropW.Value, obj.Ui.CropH.Value];
        end

        function c = cropControls(obj)
            c = [obj.Ui.CropX, obj.Ui.CropY, obj.Ui.CropW, obj.Ui.CropH, obj.Ui.CropCenter, obj.Ui.CropApply, ...
                obj.Ui.CropReset];
        end

        % ---------------------------------------------------------------- helpers
        function pushOutputSettings(obj)
            cm = obj.Manager;
            cm.DataRoot = obj.Ui.DataRoot.Value;
            cm.AppendDateTime = obj.Ui.AppendDateTime.Value;
            if ~strcmp(cm.State, 'recording')
                cm.Recorder.Format = obj.Ui.Format.Value;
            end
        end

        function updateOutputPreview(obj)
            P = obj.Palette;
            cm = obj.Manager;
            if strcmp(cm.State, 'recording') && isfield(cm.CurrentRecording, 'Folder')
                plan = cm.CurrentRecording;
                lines = [{plan.Folder}, cellfun(@(f) ['  ' fileName(f)], {plan.Cameras.CsvFile}, ...
                    'UniformOutput', false)];
                obj.Ui.OutputPreview.Text = strjoin(lines, newline);
                obj.Ui.OutputPreview.FontColor = P.Recording;
                return
            end
            try
                folder = obj.outputFolder();
            catch
                obj.Ui.OutputPreview.Text = sprintf('Enter a subject name.\nFiles go to %s\\<subject>\\<session>', ...
                    obj.Ui.DataRoot.Value);
                obj.Ui.OutputPreview.FontColor = P.Armed;
                return
            end
            lines = {folder};
            if isempty(cm.Cameras)
                lines{end + 1} = '  (connect a camera to see file names)';
            else
                names = cm.plannedFileNames(obj.Ui.FileName.Value);
                ext = cm.Recorder.extension();
                for k = 1:numel(names.Cameras)
                    if isempty(ext)
                        lines{end + 1} = sprintf('  %s.csv', names.Cameras{k}); %#ok<AGROW>
                    else
                        lines{end + 1} = sprintf('  %s%s + .csv', names.Cameras{k}, ext); %#ok<AGROW>
                    end
                end
                lines{end + 1} = sprintf('  %s_events.csv / _session.json', names.Shared);
            end
            obj.Ui.OutputPreview.Text = strjoin(lines, newline);
            obj.Ui.OutputPreview.FontColor = P.Muted;
        end

        function updateSyncFields(obj)
            P = obj.Palette;
            fields = obj.Ui.SyncFields;
            mode = obj.Ui.Mode.Value;
            recording = strcmp(obj.Manager.State, 'recording');
            relevant = spincam.SyncController.optionsFor(mode, fields.TtlSource.Control.Value);
            names = fieldnames(fields);
            for k = 1:numel(names)
                on = ~recording && any(strcmp(relevant, names{k}));
                set([fields.(names{k}).Label, fields.(names{k}).Control], 'Enable', onOff(on));
            end
            obj.Ui.Mode.Enable = onOff(~recording);
            obj.Ui.SyncHelp.Text = obj.SyncHelp.(mode);
            stylePanel(obj.Ui.TriggerPanel, 'Trigger', strcmp(mode, 'triggered'), 'B · hardware trigger', P);
            stylePanel(obj.Ui.StrobePanel, 'Strobe output', strcmp(mode, 'strobe'), 'C · strobe', P);

            obj.Ui.ApplySync.Enable = onOff(~recording);
            if recording
                obj.Ui.SyncStatus.Text = ['Locked while recording. Active: ' obj.Manager.Sync.describe()];
                obj.Ui.SyncStatus.FontColor = P.Muted;
            elseif obj.syncPending()
                obj.Ui.SyncStatus.Text = 'Not applied yet (applied automatically on Preview / Record).';
                obj.Ui.SyncStatus.FontColor = P.Armed;
            else
                obj.Ui.SyncStatus.Text = ['Active: ' obj.Manager.Sync.describe()];
                obj.Ui.SyncStatus.FontColor = P.Preview;
            end
        end

        function args = syncArgs(obj)
            %SYNCARGS Name-value pairs for the options the selected mode uses.
            fields = obj.Ui.SyncFields;
            relevant = spincam.SyncController.optionsFor(obj.Ui.Mode.Value, fields.TtlSource.Control.Value);
            args = {};
            for k = 1:numel(relevant)
                if isfield(fields, relevant{k})
                    args = [args, {relevant{k}, fields.(relevant{k}).Control.Value}]; %#ok<AGROW>
                end
            end
        end

        function tf = syncPending(obj)
            s = obj.Manager.Sync;
            tf = ~strcmp(s.Mode, obj.Ui.Mode.Value);
            args = obj.syncArgs();
            for k = 1:2:numel(args)
                current = s.(args{k});
                wanted = args{k + 1};
                if ischar(current) || isstring(current)
                    same = strcmpi(char(current), char(wanted));
                else
                    same = isequal(double(current), double(wanted));
                end
                tf = tf || ~same;
            end
        end

        function refreshControls(obj)
            names = obj.PropertyNames;
            cams = obj.Manager.Cameras;
            obj.UpdatingControls = true;
            restore = onCleanup(@() obj.setUpdating(false));
            for k = 1:numel(names)
                w = obj.Ui.Props.(names{k});
                set([w.Slider, w.Spinner, w.Auto], 'Enable', 'off');
            end
            obj.refreshCrop();
            if isempty(cams)
                return
            end
            ids = obj.targetIds();
            if isempty(ids)
                dev = cams(1);
            else
                dev = obj.Manager.camera(ids{1});
            end
            nm = dev.NodeMap;
            for k = 1:numel(names)
                name = names{k};
                w = obj.Ui.Props.(name);
                def = spincam.internal.PropertyRegistry.lookup(name);
                node = nm.firstExisting(def.Nodes);
                if isempty(node)
                    continue
                end
                s = nm.info(node);
                if isfield(obj.AutoProperties, name)
                    autoDef = spincam.internal.PropertyRegistry.lookup(obj.AutoProperties.(name));
                    autoNode = nm.firstExisting(autoDef.Nodes);
                    if ~isempty(autoNode) && nm.isReadable(autoNode)
                        w.Auto.Value = ~strcmp(nm.get(autoNode), 'Off');
                        w.Auto.Enable = onOff(nm.isWritable(autoNode));
                    end
                end
                if ~s.Available || ~s.Readable || isempty(s.Value)
                    continue
                end
                lo = s.Min;
                hi = s.Max;
                if isempty(lo)
                    lo = min(0, s.Value);
                end
                if isempty(hi)
                    hi = max(1, s.Value);
                end
                if hi <= lo
                    hi = lo + max(abs(lo) * 0.01, 1e-3);
                end
                value = min(max(s.Value, lo), hi);
                w.Slider.Limits = [lo hi];
                w.Slider.Value = value;
                w.Spinner.Limits = [lo hi];
                w.Spinner.Step = (hi - lo) / 100;
                w.Spinner.Value = value;
                set([w.Slider, w.Spinner], 'Enable', 'on');
            end
        end

        function setUpdating(obj, value)
            if isvalid(obj)
                obj.UpdatingControls = value;
            end
        end

        function ids = targetIds(obj)
            ids = {};
            if ~isempty(obj.Ui.Target.Value)
                ids = {obj.Ui.Target.Value};
            end
        end

        function syncWidgetsFromManager(obj)
            s = obj.Manager.Sync;
            obj.Ui.Mode.Value = s.Mode;
            fields = obj.Ui.SyncFields;
            names = fieldnames(fields);
            for k = 1:numel(names)
                control = fields.(names{k}).Control;
                value = s.(names{k});
                if ~isprop(control, 'Items')
                    control.Value = value;
                elseif ~isempty(control.ItemsData)
                    if any(strcmp(control.ItemsData, value))
                        control.Value = value;
                    end
                elseif any(strcmp(control.Items, value))
                    control.Value = value;
                end
            end
        end

        function message(obj, text, isError)
            obj.LastMessage = text;
            if isvalid(obj.Figure)
                obj.Ui.Message.Text = text;
                obj.Ui.Message.FontColor = obj.Palette.Muted;
                if isError
                    obj.Ui.Message.FontColor = obj.Palette.Error;
                    if strcmp(obj.Figure.Visible, 'on')
                        uialert(obj.Figure, text, 'SpinCam');
                    end
                end
            end
        end
    end
end

function p = sectionPanel(parent, title, P)
p = uipanel(parent, 'Title', title, 'FontWeight', 'bold', 'FontSize', 13, 'BackgroundColor', P.Surface, ...
    'ForegroundColor', P.Accent, 'BorderType', 'line');
end

function stylePanel(panel, title, active, modeName, P)
if active
    panel.Title = title;
    panel.ForegroundColor = P.Accent;
else
    panel.Title = sprintf('%s · used in %s mode only', title, modeName);
    panel.ForegroundColor = P.Muted;
end
end

function g = syncGrid(panel, rows, P)
g = uigridlayout(panel, [rows 2], 'RowHeight', repmat({'fit'}, 1, rows), 'ColumnWidth', {110, '1x'}, ...
    'BackgroundColor', P.Surface);
end

function field = syncField(grid, label, control, tooltip)
lbl = uilabel(grid, 'Text', label, 'Tooltip', tooltip);
control.Tooltip = tooltip;
field = struct('Label', lbl, 'Control', control);
end

function s = cropSpinner(grid, step, callback)
s = uispinner(grid, 'Limits', [0 8192], 'Step', step, 'RoundFractionalValues', 'on', 'ValueDisplayFormat', '%.0f', ...
    'ValueChangedFcn', @(~, ~) callback());
end

function lbl = addLabel(grid, text, tooltip)
lbl = uilabel(grid, 'Text', text, 'Tooltip', tooltip);
end

function labels = formatLabels()
labels = {'avi-mjpeg-mt · MJPEG AVI (native, multi-core)', 'avi-mjpeg · MJPEG AVI (SpinVideo)', 'avi-raw · uncompressed AVI (native)', ...
    'mp4-h264 · H.264 MP4 (native)', 'raw · lossless .raw (native, any fps)', ...
    'matlab-avi · Grayscale AVI (MATLAB)', 'matlab-mjpeg · MJPEG AVI (MATLAB)', 'none · CSV only'};
end

function t = tileTitle(dev)
t = sprintf('%s   ·   %s', dev.Name, dev.Serial);
end

function t = frameRateText(rate)
if isempty(rate)
    t = 'their current frame rate';
else
    t = sprintf('%g fps', rate);
end
end

function name = fileName(path)
[~, stem, ext] = fileparts(path);
name = [stem ext];
end

function v = onOff(tf)
if tf
    v = 'on';
else
    v = 'off';
end
end
