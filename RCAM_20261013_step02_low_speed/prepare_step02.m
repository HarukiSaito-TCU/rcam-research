% Check STEP02, then open it. Initial speed and controller settings are unchanged.
stepFolder=fileparts(mfilename('fullpath'));
baselineFolder=fullfile(fileparts(stepFolder),'RCAM_20261013_step01_ground_unified');
addpath(baselineFolder,'-begin');
addpath(stepFolder,'-begin');
clear RCAM_dynamics_fcn20261013_step02_brake RCAM_monitor_20261013_step02 RCAM_dynamics_fcn20261009_brake
assert(strcmpi(which('RCAM_dynamics_fcn20261013_step02_brake'),fullfile(stepFolder,'RCAM_dynamics_fcn20261013_step02_brake.m')));
assert(strcmpi(which('RCAM_dynamics_fcn20261009_brake'),fullfile(baselineFolder,'RCAM_dynamics_fcn20261009_brake.m')));
checkU=[0;-0.1507342990954698;0;0.08116818704192683;0.08116818704192683];
velocities=[0 0 0;1e-12 0 0;0 1e-12 0;0 0 1e-12;0.3 0.4 0;77.0814 0 0;85 0 0];
for rowIndex=1:size(velocities,1)
    for checkHeight=[0,50]
        checkX=zeros(12,1);
        checkX(1:3)=velocities(rowIndex,:)';
        checkX(12)=-checkHeight;
        % Include nonzero angular rates to test aerodynamic damping divisions.
        checkX(4:6)=[0.01;0.02;0.01];
        for checkBrake=[0,1]
            [dx,L,W,Va,alpha,N]=RCAM_dynamics_fcn20261013_step02_brake(checkX,checkU,checkBrake);
            assert(all(isfinite([dx;L;W;Va;alpha;N])),'Nonfinite low-speed output.');
            assert(isequal(RCAM_monitor_20261013_step02([checkX;checkU]),[L;W;N]));
            if Va>=0.5
                [dx0,L0,W0,Va0,alpha0,N0]=RCAM_dynamics_fcn20261009_brake(checkX,checkU,checkBrake);
                assert(isequal([dx;L;W;Va;alpha;N],[dx0;L0;W0;Va0;alpha0;N0]),'Normal-speed regression.');
            end
        end
    end
end
stepModel='RCAM_PID_takeoff_lamding_20261013_step02';
load_system(fullfile(stepFolder,[stepModel '.slx']));
set_param(stepModel,'SimulationCommand','update');
open_system(stepModel);
disp('STEP02 checks passed. Run without changing the initial speed and compare with STEP01.');
