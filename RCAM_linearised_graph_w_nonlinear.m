[out] = sim("RCAM_PID_takeoff_lamding_20260916");
t = out.h.Time(:);

h = out.h.Data;
h1 = h(:,1);
h2 = h(:,2);

theta = out.theta.Data;
theta1 = theta(:,1);
theta2 = theta(:,2);

q = out.q.Data;
q1 = q(:,1);
q2 = q(:,2);

v = out.v.Data;
v1 = v(:,1);
v2 = v(:,2);

alpha = out.alpha.Data;
alpha = alpha(:,1);


figure;

subplot(5,1,1); hold on; grid on;
plot(t, h1, '-', 'Color', 'r', 'LineWidth', 2);
plot(t, h2, '-', 'Color', 'b', 'LineWidth', 2);
xlabel('Time (s)','FontSize',15,'FontName','Times New roman');
ylabel('altitude(m)','FontSize',15,'FontName','Times New roman');

subplot(5,1,2); hold on; grid on;
plot(t,theta1,'-','Color', 'r', 'LineWidth',2);
plot(t,theta2,'-','Color', 'b', 'LineWidth',2);
xlabel('Time(s) ','FontSize',15,'FontName','Times New roman');
ylabel('pitch(deg)','FontSize',15,'FontName','Times New roman');


subplot(5,1,3); hold on; grid on;
plot(t,q1,'-','Color', 'r', 'LineWidth',2);
plot(t,q2,'-','Color', 'b','LineWidth',2);
xlabel('Time (s)','FontSize',15,'FontName','Times New roman');
ylabel('Pitch rate(deg/s)','FontSize',15,'FontName','Times New roman');

subplot(5,1,4); hold on; grid on;
plot(t,v1,'-','Color', 'r', 'LineWidth',2);
plot(t,v2,'-','Color', 'b', 'LineWidth',2);
xlabel('Time (s)','FontSize',15,'FontName','Times New roman');
ylabel('speed(deg/s)','FontSize',15,'FontName','Times New roman');

subplot(5,1,5); hold on; grid on;
plot(t,alpha,'-','LineWidth',2);
xlabel('Time (s)','FontSize',15,'FontName','Times New roman');
ylabel('Angle of attack(deg/s)','FontSize',15,'FontName','Times New roman');