classdef PathUtilsTest < matlab.unittest.TestCase
    %PATHUTILSTEST WSL-to-Windows path conversion and file-name sanitizing.

    methods (Test)
        function convertsWslMountPaths(tc)
            f = @spincam.internal.toWindowsPath;
            tc.verifyEqual(f('/mnt/c/Users/harrislab/data'), 'C:\Users\harrislab\data');
            tc.verifyEqual(f('/mnt/d'), 'D:\');
            tc.verifyEqual(f("/mnt/e/x y/z"), 'E:\x y\z');
        end

        function normalizesDriveForwardSlashes(tc)
            tc.verifyEqual(spincam.internal.toWindowsPath('C:/data/run1'), 'C:\data\run1');
        end

        function leavesOtherPathsAlone(tc)
            f = @spincam.internal.toWindowsPath;
            tc.verifyEqual(f('C:\already\windows'), 'C:\already\windows');
            tc.verifyEqual(f('relative/path'), 'relative/path');
            tc.verifyEqual(f('\\server\share'), '\\server\share');
            tc.verifyEqual(f('/mnt/cc/not-a-drive'), '/mnt/cc/not-a-drive');
        end

        function cleansCameraAndFileNameParts(tc)
            f = @spincam.CameraManager.cleanName;
            tc.verifyEqual(f('top view!'), 'top_view');
            tc.verifyEqual(f('  mouse-01 '), 'mouse-01');
            tc.verifyEqual(f('a/b\c.d'), 'a_b_c_d');
            tc.verifyEqual(f('__'), '');
            tc.verifyEqual(f("sideview"), 'sideview');
        end

        function sanitizesFileNames(tc)
            f = @spincam.internal.sanitizeFileName;
            tc.verifyEqual(f('a:b/c?d'), 'a_b_c_d');
            tc.verifyEqual(f('trailing. '), 'trailing');
            tc.verifyEqual(f(''), 'session');
            tc.verifyEqual(f("mouse01_day1"), 'mouse01_day1');
        end
    end
end
