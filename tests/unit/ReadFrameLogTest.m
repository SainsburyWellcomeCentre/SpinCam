classdef ReadFrameLogTest < matlab.unittest.TestCase
    %READFRAMELOGTEST spincam.io.readFrameLog on written logs, and the 128 s timestamp steps.
    %   Engines before 1.3.0 logged the Chameleon3's spurious 128 s steps as they came
    %   (LUMS0014 2026-09-26 and 2026-09-28); the reader takes them out of such logs.

    properties
        OutDir
    end

    methods (TestMethodSetup)
        function makeOutputFolder(tc)
            tc.OutDir = fullfile(fileparts(fileparts(fileparts(mfilename('fullpath')))), ...
                'tests', '_output', sprintf('ReadFrameLogTest_%d', randi(1e9)));
            mkdir(tc.OutDir);
            tc.addTeardown(@() rmdir(tc.OutDir, 's'));
        end
    end

    methods (Test)
        function stepsOfWholeWrapsAreTakenOut(tc)
            % A +128 s step at frame 4 and a +256 s step at frame 8, as the camera's
            % double-counted wraps; the host clock runs on at 10 ms a frame.
            n = 12;
            host = 24.9 + 0.01 * (0:n - 1)';
            hardware = 1127130990021 + 10000 * (0:n - 1)';
            hardware(4:end) = hardware(4:end) + 128e6;
            hardware(8:end) = hardware(8:end) + 256e6;
            path = tc.writeLog(hardware, host, true);
            [T, corrections] = spincam.io.readFrameLog(path);
            tc.verifyEqual(corrections, 2);
            tc.verifyEqual(diff(T.HardwareTimestamp_us), 10000 * ones(n - 1, 1));
            tc.verifyEqual(T.HardwareTimestamp_us(1), 1127130990021);
        end

        function aRealGapIsKept(tc)
            % Frames missed for 3 s show on both clocks: nothing to correct.
            host = [0; 0.01; 3.01; 3.02];
            hardware = 5e12 + 1e6 * host;
            [T, corrections] = spincam.io.readFrameLog(tc.writeLog(hardware, host, true));
            tc.verifyEqual(corrections, 0);
            tc.verifyEqual(T.HardwareTimestamp_us, hardware);
        end

        function correctionCanBeSwitchedOff(tc)
            host = 0.01 * (0:3)';
            hardware = 5e12 + 1e4 * (0:3)' + [0; 0; 128e6; 128e6];
            path = tc.writeLog(hardware, host, true);
            [T, corrections] = spincam.io.readFrameLog(path, 'CorrectTimestampSteps', false);
            tc.verifyEqual(corrections, 0);
            tc.verifyEqual(T.HardwareTimestamp_us, hardware);
        end

        function aCompactLogIsLeftAsWritten(tc)
            host = 0.01 * (0:3)';
            hardware = 5e12 + 1e4 * (0:3)' + [0; 0; 128e6; 128e6];
            [T, corrections] = spincam.io.readFrameLog(tc.writeLog(hardware, host, false));
            tc.verifyEqual(corrections, 0, 'No host clock to compare with');
            tc.verifyEqual(T.HardwareTimestamp_us, hardware);
        end
    end

    methods (Access = private)
        function path = writeLog(tc, hardware, host, extended)
            % A frame log in the engine's layout (CsvFrameLog), compact or extended.
            path = fullfile(tc.OutDir, sprintf('log%d.csv', randi(1e9)));
            fid = fopen(path, 'w');
            closer = onCleanup(@() fclose(fid));
            header = 'FrameNumber,CameraID,HardwareTimestamp_us,HostTimestamp_datetime,TTL_State,DroppedFrameFlag';
            if extended
                header = [header ',DeviceFrameID,EmbeddedFrameCounter,FramesMissedBefore,HostTime_s,' ...
                    'GPIO_LineStatus,TTL_Source,VideoFrameIndex,WriterDropFlag,IncompleteFlag'];
            end
            fprintf(fid, '%s\n', header);
            for k = 1:numel(hardware)
                fprintf(fid, '%d,SIM1,%d,2026-09-28T12:37:28.945707+01:00,0,0', k - 1, hardware(k));
                if extended
                    fprintf(fid, ',%d,%d,0,%.6f,8,embedded,%d,0,0', k + 4, k + 1000, host(k), k - 1);
                end
                fprintf(fid, '\n');
            end
        end
    end
end
