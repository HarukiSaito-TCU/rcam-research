% Run this file to select the STEP01 snapshot and check the model.
stepFolder = fileparts(mfilename('fullpath'));
addpath(stepFolder, '-begin');
clear RCAM_dynamics_fcn20261009_brake RCAM_monitor_20261013_step01
resolvedDynamics = which('RCAM_dynamics_fcn20261009_brake');
assert(strcmpi(resolvedDynamics, fullfile(stepFolder, 'RCAM_dynamics_fcn20261009_brake.m')), ...
    'The dynamics function must resolve to the STEP01 folder.');
% Check both contact and airborne states, with released and applied brakes.
checkStates = [77.0814,85; zeros(10,2); 0,-50];
checkInput = [0;-0.1507342990954698;0;0.08116818704192683;0.08116818704192683];
for stateIndex = 1:2
    checkX = checkStates(:,stateIndex);
    monitorValues = RCAM_monitor_20261013_step01([checkX;checkInput]);
    for checkBrake = [0,1]
        [~,checkL,checkW,~,~,checkN] = RCAM_dynamics_fcn20261009_brake(checkX,checkInput,checkBrake);
        assert(isequal(monitorValues,[checkL;checkW;checkN]), 'Monitor output mismatch.');
    end
end
stepModel = 'RCAM_PID_takeoff_lamding_20261013_step01';
load_system(fullfile(stepFolder,[stepModel '.slx']));
set_param(stepModel,'SimulationCommand','update');
open_system(stepModel);
disp('STEP01 checks passed. Run the model and compare h, theta, V and N_ground.');
