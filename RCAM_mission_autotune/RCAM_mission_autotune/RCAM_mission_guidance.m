function y = RCAM_mission_guidance(z)
% Discrete outer-loop guidance. States are explicit Unit Delay signals.
% Input: h,hdot,V,alpha,time,phase,elapsed,I,previousTheta,Kp,Ki,Kd.
% Output: thetaRef,hRef,VRef,phase,elapsed,I,thetaRef.
dt=0.05;
h=z(1); hd=z(2); V=z(3); alpha=z(4);
phase=round(z(6)); elapsed=z(7); integral=z(8); oldTheta=z(9);
kp=z(10); ki=z(11); kd=z(12);
target=914.4;
oldPhase=phase;
if phase==0 && V>=84
    phase=1;
elseif phase==1 && h>=20
    phase=2;
elseif phase==2 && abs(h-target)<10 && abs(hd)<0.5
    phase=3;
elseif phase==3 && elapsed>=30
    phase=4;
elseif phase==4 && h<=12 && target-3*elapsed<=12
    phase=5;
elseif phase==5 && h<=0.02 && abs(hd)<1
    phase=6;
end
if phase~=oldPhase
    elapsed=0; integral=0;
end
hRef=target;
VRef=100;
if phase<=1
    VRef=90;
elseif phase==4
    hRef=max(10,target-3*elapsed);
    VRef=85+15*hRef/target;
elseif phase>=5
    hRef=0; VRef=85;
    if phase==6, VRef=0; end
end
if phase==0
    desiredTheta=0;
elseif phase==1
    desiredTheta=8*pi/180;
elseif phase==6
    desiredTheta=0;
else
    errorH=hRef-h;
    feedforward=0;
    if phase==4 && hRef>10, feedforward=-3; end
    raw=feedforward+kp*errorH+ki*integral-kd*hd;
    verticalCommand=min(6,max(-3,raw));
    % Conditional integration avoids altitude integrator windup.
    if phase<=4 && (raw==verticalCommand || ...
            (raw>6 && errorH<0) || (raw<-3 && errorH>0))
        integral=integral+dt*errorH;
    end
    if phase==5
        verticalCommand=-max(0.25,min(1,0.08*max(h,0)));
        integral=0;
    end
    % Current alpha supplies the airspeed-dependent trim pitch offset.
    % Additional vertical-speed feedback damps capture and descent.
    desiredGamma=asin(min(0.25,max(-0.25, ...
        (verticalCommand+0.4*(verticalCommand-hd))/max(V,1))));
    desiredTheta=alpha+desiredGamma;
end
desiredTheta=min(10*pi/180,max(-12*pi/180,desiredTheta));
thetaRef=oldTheta+min(2*pi/180*dt,max(-2*pi/180*dt,desiredTheta-oldTheta));
if phase==3
    if abs(h-target)<15 && abs(hd)<0.5
        elapsed=elapsed+dt;
    else
        elapsed=0;
    end
else
    elapsed=elapsed+dt;
end
y=[thetaRef;hRef;VRef;phase;elapsed;integral;thetaRef];
end
