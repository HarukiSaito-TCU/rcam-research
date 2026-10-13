% Verify the SAME saved model used by the Simulink Run button.
% Place beside RCAM_PID_takeoff_leveloff_trial.slx and the dynamics files.
% Does not rewire or retune controllers, or change StopTime/solver settings.
folder=fileparts(mfilename('fullpath'));
addpath(folder,'-begin');
clear RCAM_dynamics_fcn20260918 RCAM_monitor
model='RCAM_PID_takeoff_leveloff_trial';
modelFile=fullfile(folder,[model '.slx']);
assert(isfile(modelFile),'Place this script beside the leveloff SLX file.');
if bdIsLoaded(model)
    loadedFile=get_param(model,'FileName');
    assert(strcmpi(loadedFile,modelFile), ...
        'A same-named model from another folder is open. Close it first.');
end
load_system(modelFile);
plant=[model '/Nonlinear 6DOF RCAM Aircraft Plant Model'];
alt=[model '/Alltitude control'];
set_param(model,'SignalLogging','on','SignalLoggingName','logsout');
sources={plant,2,'theta_actual';plant,3,'altitude'; ...
    plant,5,'airspeed';alt,1,'theta_command';alt,2,'altitude_reference'; ...
    [plant '/RCAM FUNCTION1'],1,'forces'};
for k=1:size(sources,1)
    ports=get_param(sources{k,1},'PortHandles');
    set_param(ports.Outport(sources{k,2}), ...
        'DataLogging','on','DataLoggingNameMode','Custom', ...
        'DataLoggingName',sources{k,3});
end
set_param(model,'SimulationCommand','update');
% Persist the exact in-memory settings, so reopening and Run use this model.
save_system(model,modelFile);
fprintf('Model: %s\n',get_param(model,'FileName'));
fprintf('StopTime: %s; MaxStep: %s; Solver: %s\n', ...
    get_param(model,'StopTime'),get_param(model,'MaxStep'),get_param(model,'Solver'));
fprintf('Dynamics: %s\n',which('RCAM_dynamics_fcn20260918'));
disp('MODEL_COMPILE_OK');
result=sim(model,'ReturnWorkspaceOutputs','on');
save(fullfile(folder,'leveloff_trial_results.mat'),'result');
theta=result.logsout.get('theta_actual').Values;
h=result.logsout.get('altitude').Values;
hRef=result.logsout.get('altitude_reference').Values;
V=result.logsout.get('airspeed').Values;
cmd=result.logsout.get('theta_command').Values;
forces=result.logsout.get('forces').Values;
figure('Name','RCAM saved leveloff model');
subplot(4,1,1); plot(h.Time,h.Data,hRef.Time,hRef.Data);
ylabel('h [m]'); legend({'actual','reference'}); grid on
subplot(4,1,2); plot(theta.Time,theta.Data*180/pi, ...
    cmd.Time,cmd.Data*180/pi); ylabel('theta [deg]');
legend({'actual','command'}); grid on
subplot(4,1,3); plot(V.Time,V.Data); ylabel('V [m/s]'); grid on
subplot(4,1,4); plot(forces.Time,forces.Data); ylabel('Force [N]');
legend({'L','W','N ground'}); xlabel('Time [s]'); grid on
fprintf('Final altitude %.3f m; final reference %.3f m\n', ...
    h.Data(end),hRef.Data(end));
open_system(model);
disp('Run the displayed model directly using the same saved settings.');
