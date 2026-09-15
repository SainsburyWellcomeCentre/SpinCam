function results = runTests(suiteName)
%RUNTESTS Run the spincam test suites.
%   runTests()               unit + integration (no cameras needed)
%   runTests('unit')         MATLAB-only logic
%   runTests('integration')  engine with synthetic cameras
%   runTests('hardware')     unit + integration + attached-camera tests
%   In -batch mode a failing run raises an error so the process exit code is non-zero.
arguments
    suiteName (1,:) char {mustBeMember(suiteName, {'default', 'unit', 'integration', 'hardware'})} = 'default'
end
import matlab.unittest.TestSuite
import matlab.unittest.TestRunner

root = fileparts(mfilename('fullpath'));
addpath(root);
switch suiteName
    case 'unit'
        folders = {'unit'};
    case 'integration'
        folders = {'integration'};
    case 'hardware'
        folders = {'unit', 'integration', 'hardware'};
    otherwise
        folders = {'unit', 'integration'};
end
suite = matlab.unittest.Test.empty;
for k = 1:numel(folders)
    folder = fullfile(root, 'tests', folders{k});
    if isfolder(folder)
        suite = [suite, TestSuite.fromFolder(folder, 'IncludingSubfolders', true)]; %#ok<AGROW>
    end
end
runner = TestRunner.withTextOutput();
results = runner.run(suite);
fprintf('\n%d passed, %d failed, %d incomplete (%.1f s)\n', nnz([results.Passed]), ...
    nnz([results.Failed]), nnz([results.Incomplete]), sum([results.Duration]));
if any([results.Failed]) && batchStartupOptionUsed
    error('spincam:tests:failed', '%d test(s) failed.', nnz([results.Failed]));
end
end
