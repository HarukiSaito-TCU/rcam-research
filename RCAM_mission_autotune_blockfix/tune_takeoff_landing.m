% Build and tune a separate 3000-ft mission model using the actual Simulink
% plant. No candidate is called tuned unless capture and contact checks pass.
folder=fileparts(mfilename('fullpath'));
addpath(folder,'-begin');
clear RCAM_dynamics_fcn20260918 RCAM_monitor RCAM_mission_guidance
model='RCAM_PID_mission_trial';
source='RCAM_PID_takeoff_leveloff_trial';
if bdIsLoaded(model)
    error('Close RCAM_PID_mission_trial before running the tuning script.');
end
sourceFile=fullfile(folder,[source '.slx']);
if ~isfile(sourceFile)
    error('RCAM:MissingSource', ...
        'Source model is missing: %s\nExtract the entire ZIP into one folder.',sourceFile);
end
if bdIsLoaded(source)
    loadedFile=get_param(source,'FileName');
    expectedPath=char(java.io.File(sourceFile).getCanonicalPath());
    loadedPath=char(java.io.File(loadedFile).getCanonicalPath());
    if ~strcmpi(expectedPath,loadedPath)
        if strcmp(get_param(source,'Dirty'),'on')
            error('RCAM:UnsavedSource', ...
                ['A different source model has unsaved changes: %s\n' ...
                 'Save or discard those changes yourself, close that model, and retry.'],loadedFile);
        end
        close_system(source,0);
    elseif strcmp(get_param(source,'Dirty'),'on')
        error('RCAM:UnsavedSource', ...
            'Save or discard changes in %s and close it before retrying.',source);
    end
end
fprintf('Loading source model: %s\n',sourceFile);
try
    load_system(sourceFile);
catch loadProblem
    fprintf(2,'%s\n',getReport(loadProblem,'extended','hyperlinks','off'));
    rethrow(loadProblem);
end
save_system(source,fullfile(folder,[model '.slx']));
load_system(fullfile(folder,[model '.slx']));
plant=[model '/Nonlinear 6DOF RCAM Aircraft Plant Model'];
alt=[model '/Alltitude control'];
speed=[model '/Velocity control'];
emptySubsystem(alt);
emptySubsystem(speed);

% Explicit sampled guidance: no hidden persistent state between simulations.
labels={'h','hdot','V','alpha'};
for k=1:4
    add_block('simulink/Sources/In1',[alt '/' labels{k}], ...
        'Port',num2str(k),'Position',[20 30+50*k 50 50+50*k]);
end
add_block('simulink/Sources/Clock',[alt '/Clock'],'Position',[20 300 50 320]);
add_block('simulink/Discrete/Unit Delay',[alt '/Guidance state'], ...
    'SampleTime','0.05','InitialCondition','[0;0;0;0]', ...
    'Position',[450 350 490 390]);
add_block('simulink/Sources/Constant',[alt '/Altitude PID gains'], ...
    'Value','[0.04;0.0002;0.3]','Position',[20 400 150 430]);
add_block('simulink/Signal Routing/Mux',[alt '/Guidance inputs'], ...
    'Inputs','7','Position',[180 80 185 440]);
add_block('simulink/Discrete/Zero-Order Hold',[alt '/Guidance sampling'], ...
    'SampleTime','0.05','Position',[220 240 265 270]);
% Copy the existing interpreted block; its library path varies by release.
add_block([plant '/RCAM FUNCTION'], ...
    [alt '/Mission guidance'],'MATLABFcn','RCAM_mission_guidance(u)', ...
    'OutputDimensions','7','Position',[290 230 430 275]);
add_block('simulink/Signal Routing/Demux',[alt '/Guidance outputs'], ...
    'Outputs','[1 1 1 4]','Position',[470 100 475 300]);
add_block('simulink/Signal Routing/Demux',[alt '/State outputs'], ...
    'Outputs','4','Position',[540 330 545 430]);
outNames={'theta_ref','h_ref','V_ref','phase'};
for k=1:4
    add_block('simulink/Sinks/Out1',[alt '/' outNames{k}], ...
        'Port',num2str(k),'Position',[600 30+60*k 630 50+60*k]);
end
for k=1:4
    add_line(alt,[labels{k} '/1'],['Guidance inputs/' num2str(k)],'autorouting','on');
end
add_line(alt,'Clock/1','Guidance inputs/5','autorouting','on');
add_line(alt,'Guidance state/1','Guidance inputs/6','autorouting','on');
add_line(alt,'Altitude PID gains/1','Guidance inputs/7','autorouting','on');
add_line(alt,'Guidance inputs/1','Guidance sampling/1','autorouting','on');
add_line(alt,'Guidance sampling/1','Mission guidance/1','autorouting','on');
add_line(alt,'Mission guidance/1','Guidance outputs/1','autorouting','on');
for k=1:3
    add_line(alt,['Guidance outputs/' num2str(k)],[outNames{k} '/1'],'autorouting','on');
end
add_line(alt,'Guidance outputs/4','Guidance state/1','autorouting','on');
add_line(alt,'Guidance outputs/4','State outputs/1','autorouting','on');
add_line(alt,'State outputs/1','phase/1','autorouting','on');

% Replace time-selected speed gains by one PI controller with anti-windup.
add_block('simulink/Sources/In1',[speed '/V'],'Port','1','Position',[20 50 50 70]);
add_block('simulink/Sources/In1',[speed '/Vref'],'Port','2','Position',[20 100 50 120]);
add_block('simulink/Math Operations/Sum',[speed '/Speed error'], ...
    'Inputs','+-','Position',[100 90 120 120]);
add_block('simulink/Continuous/PID Controller',[speed '/Speed PI'], ...
    'P','0.02','I','0.002','D','0','LimitOutput','on', ...
    'UpperSaturationLimit','0.1745','LowerSaturationLimit','0', ...
    'AntiWindupMode','back-calculation','Kb','1', ...
    'Position',[160 90 220 120]);
add_block('simulink/Sinks/Out1',[speed '/throttle'],'Port','1','Position',[270 90 300 110]);
add_block('simulink/Sinks/Out1',[speed '/V_ref'],'Port','2','Position',[270 140 300 160]);
add_line(speed,'Vref/1','Speed error/1','autorouting','on');
add_line(speed,'V/1','Speed error/2','autorouting','on');
add_line(speed,'Speed error/1','Speed PI/1','autorouting','on');
add_line(speed,'Speed PI/1','throttle/1','autorouting','on');
add_line(speed,'Vref/1','V_ref/1','autorouting','on');

% Restore parent connections after rebuilding subsystem interfaces.
connectInput(model,plant,3,alt,1);
connectInput(model,plant,4,alt,2);
connectInput(model,plant,5,alt,3);
connectInput(model,plant,6,alt,4);
connectInput(model,plant,5,speed,1);
connectInput(model,alt,3,speed,2);
connectInput(model,alt,1,[model '/Sum1'],2);
connectInput(model,speed,1,[model '/Mux'],4);
connectInput(model,speed,1,[model '/Mux'],5);
% Existing pitch/rate loops remain P=20 and PI=40,9 as in the working trial.
connectInput(model,alt,2,[model '/Mux1'],2);
connectInput(model,alt,1,[model '/Mux4'],2);
connectInput(model,speed,2,[model '/Mux2'],2);
% Initial state: horizontal rolling at 77.0814 m/s, zero vertical speed.
set_param([plant '/Integrator'],'InitialCondition', ...
    '[77.0814;0;0;0;0;0;0;0;0;0;0;0]');
set_param(model,'StopTime','700','MaxStep','0.01', ...
    'SignalLogging','on','SignalLoggingName','logsout');
names={plant,2,'theta';plant,3,'h';plant,4,'hdot';plant,5,'V'; ...
    plant,6,'alpha';plant,1,'q'; ...
    alt,1,'theta_ref';alt,2,'h_ref';alt,4,'phase'; ...
    [plant '/RCAM FUNCTION1'],1,'forces'; ...
    [plant '/Saturation1'],1,'stabilizer';speed,1,'throttle'};
for k=1:size(names,1)
    ports=get_param(names{k,1},'PortHandles');
    set_param(ports.Outport(names{k,2}),'DataLogging','on', ...
        'DataLoggingNameMode','Custom','DataLoggingName',names{k,3});
end
set_param(model,'SimulationCommand','update');
save_system(model,fullfile(folder,[model '.slx']));
% Small explicit search of altitude PID gains. These are candidate values.
candidates=[0.02 0 0.3;0.04 0 0.3;0.06 0 0.6; ...
    0.02 0.0002 0.3;0.04 0.0002 0.3;0.04 0.0005 0.6];
report=nan(size(candidates,1),8);
failures=cell(size(candidates,1),1);
bestCost=inf; bestIndex=0;
for k=1:size(candidates,1)
    fprintf('Candidate %d/%d: Kp=%g Ki=%g Kd=%g\n', ...
        k,size(candidates,1),candidates(k,:));
    set_param([alt '/Altitude PID gains'],'Value',mat2str(candidates(k,:).'));
    try
        run=sim(model,'ReturnWorkspaceOutputs','on');
        [cost,pass,overshoot,holdError,touchdown]=assess(run);
        report(k,:)=[candidates(k,:) cost double(pass) overshoot holdError touchdown];
        if pass && cost<bestCost
            bestCost=cost; bestIndex=k; bestRun=run;
        end
    catch problem
        fprintf('Candidate failed: %s\n',problem.message);
        failures{k}=getReport(problem,'extended','hyperlinks','off');
    end
end
report=array2table(report,'VariableNames', ...
    {'Kp','Ki','Kd','Cost','Pass','Overshoot_m','HoldError_m','Touchdown_s'});
writetable(report,fullfile(folder,'tuning_report.csv'));
disp(report);
save(fullfile(folder,'tuning_diagnostics.mat'),'failures','report');
if bestIndex==0
    save(fullfile(folder,'tuning_failed.mat'),'report');
    error('RCAM:NoPassingCandidate', ...
        'No candidate passed. Trial model is not validated. Send tuning_report.csv.');
end
bestGains=candidates(bestIndex,:);
set_param([alt '/Altitude PID gains'],'Value',mat2str(bestGains.'));
save_system(model,fullfile(folder,[model '.slx']));
save(fullfile(folder,'mission_best_results.mat'),'bestRun','bestGains','report');
plotRun(bestRun);
open_system(model);
fprintf('PASS: saved gains %s. Direct Simulink Run uses these same settings.\n',mat2str(bestGains));

function emptySubsystem(system)
blocks=find_system(system,'SearchDepth',1,'Type','block');
for k=2:numel(blocks), delete_block(blocks{k}); end
lines=find_system(system,'FindAll','on','SearchDepth',1,'Type','line');
for k=1:numel(lines)
    try
        delete_line(lines(k));
    catch
        % Deleting a parent line also deletes its branch handles.
    end
end
end

function connectInput(system,source,number,dest,destNumber)
sp=get_param(source,'PortHandles'); dp=get_param(dest,'PortHandles');
line=get_param(dp.Inport(destNumber),'Line');
if line~=-1
    old=get_param(line,'SrcPortHandle');
    if old==-1
        delete_line(line);
    elseif old==sp.Outport(number)
        return
    else
        oldBlock=get_param(old,'Parent'); oldNumber=get_param(old,'PortNumber');
        delete_line(system,[get_param(oldBlock,'Name') '/' num2str(oldNumber)], ...
            [get_param(dest,'Name') '/' num2str(destNumber)]);
    end
end
sp=get_param(source,'PortHandles'); dp=get_param(dest,'PortHandles');
add_line(system,sp.Outport(number),dp.Inport(destNumber),'autorouting','on');
end

function [cost,pass,overshoot,holdError,touchdown]=assess(run)
h=run.logsout.get('h').Values;
hd=run.logsout.get('hdot').Values;
phase=run.logsout.get('phase').Values;
forces=run.logsout.get('forces').Values;
alpha=run.logsout.get('alpha').Values;
theta=run.logsout.get('theta').Values;
p=interp1(phase.Time,double(phase.Data(:)),h.Time,'previous','extrap');
hold=p==3; ground=p==6;
overshoot=max(0,max(h.Data(:))-914.4);
holdError=inf; touchdown=nan;
if any(hold), holdError=max(abs(h.Data(hold)-914.4)); end
if any(ground), touchdown=h.Time(find(ground,1)); end
pass=all(isfinite(h.Data(:))) && any(hold) && any(p==4) && any(p==5) && any(ground);
rotated=find(theta.Data(:)>=0.5*pi/180,1);
lifted=find(h.Data(:)>=1,1);
pass=pass && ~isempty(rotated) && ~isempty(lifted);
if pass
    pass=theta.Time(rotated)<h.Time(lifted) && min(h.Data(:))>-0.5 && ...
        max(abs(theta.Data(:)))<15*pi/180 && ...
        max(abs(alpha.Data(:)))<14.5*pi/180;
end
if pass
    normal=interp1(forces.Time,forces.Data(:,3),h.Time,'linear','extrap');
    vertical=interp1(hd.Time,hd.Data(:),h.Time,'linear','extrap');
    settled=h.Time>touchdown+10;
    pass=overshoot<40 && holdError<15 && sum(hold)>1 && ...
        h.Time(end)-touchdown>20 && all(h.Data(ground)<1) && ...
        any(normal(ground)>0) && any(settled) && ...
        max(abs(h.Data(settled)))<0.2 && max(abs(vertical(settled)))<0.2;
end
cost=overshoot+holdError+0.01*max(h.Time);
end

function plotRun(run)
h=run.logsout.get('h').Values; hr=run.logsout.get('h_ref').Values;
th=run.logsout.get('theta').Values; tr=run.logsout.get('theta_ref').Values;
V=run.logsout.get('V').Values; phase=run.logsout.get('phase').Values;
forces=run.logsout.get('forces').Values;
figure('Name','3000 ft takeoff and landing mission');
subplot(5,1,1); plot(h.Time,h.Data,hr.Time,hr.Data); ylabel('h [m]'); legend({'actual','reference'}); grid on
subplot(5,1,2); plot(th.Time,th.Data*180/pi,tr.Time,tr.Data*180/pi); ylabel('theta [deg]'); legend({'actual','reference'}); grid on
subplot(5,1,3); plot(V.Time,V.Data); ylabel('V [m/s]'); grid on
subplot(5,1,4); plot(forces.Time,forces.Data); ylabel('Force [N]'); legend({'L','W','N'}); grid on
subplot(5,1,5); stairs(phase.Time,phase.Data); ylabel('Phase'); xlabel('Time [s]'); grid on
end
