clear
close all 

theta0 = 0.0604;
% モデル読み込み
mdl = 'test2';

mdl = 'test2';
load_system(mdl)

Vlist = [80 90 100];
alphalist = deg2rad([2 3 4]);

k = 1;
for i = 1:length(Vlist)
    for j = 1:length(alphalist)

        V = Vlist(i);
        alpha = alphalist(j);

        u0 = V*cos(alpha);
        w0 = V*sin(alpha);

        opspec = operspec(mdl);

        opspec.States(1).x(1) = u0;
        opspec.States(1).x(3) = w0;
        opspec.States(1).x(4) = 0;
        opspec.States(1).x(5) = 0;
        opspec.States(1).x(6) = 0;

        opspec.States(1).Known(1) = true;
        opspec.States(1).Known(3) = true;
        opspec.States(1).Known(4) = true;
        opspec.States(1).Known(5) = true;
        opspec.States(1).Known(6) = true;
        
        opspec.States(1).SteadyState(1) = true;
        opspec.States(1).SteadyState(3) = true;
        opspec.States(1).SteadyState(4) = true;
        opspec.States(1).SteadyState(5) = true;
        opspec.States(1).SteadyState(6) = true;
        opspec.States(1).SteadyState(10:12) = false;

        opt = findopOptions('DisplayReport','off');
        op_all{k} = findop(mdl, opspec, opt);

        k = k + 1;
    end
end


% 
% % 線形化
% io = getlinio(mdl);
% 
% optlin = linearizeOptions('LinearizationAlgorithm','blockbyblock');
% sys_lin = linearize(mdl, optrim, io, optlin);
% 
% % sys_lin = linearize(mdl, optrim, io);
% 
% 
% [A,B,C,D] = ssdata(sys_lin);
% % size(A), size(B), size(C), size(D)
% 
% %%% 可制御性確認
% Co = ctrb(A,B);
% rank(Co)
% 
% 
% 
% 
% %%
% 
% % 縦系抜き出し
% idx = [1 3 5 8]; %% 1: u,2: v, 3:w , 4:p, 5:q ,6:r ,7: phi 8: theta
% idu = [2 4 5];
% A_lon = A(idx,idx); %% 1: u, 3:w, 5:q , 8: theta
% B_lon = B(idx,idu); %% u1: ,,u2:stabilizer(elevator), u3:, u4:th1 (throttle 1) ,u5:th2 (throttle 2)
% % C_lon = eye(4);
% % D_lon = zeros(4,size(B_lon,2));
% 
% %%% 状態空間表現
% C_lon =eye(4);
% D_lon = zeros(4,3);
% %% 
% sys = ss(A_lon,B_lon,C_lon,D_lon);
% 
% %%% 可制御性確認
% Co = ctrb(A_lon,B_lon);
% rank(Co)
% 
% %% 
% V0 = sqrt(u0^2+w0^2);
% 
% % 状態量変換
% T = [1, 0, 0, 0;
%      -w0/V0^2, u0/V0^2, 0, 0;
%       0, 0, 1, 0;
%       0, 0, 0, 1];
% A_new = T*A_lon/T;
% B_new = T * B_lon;
% 
% % 拡張行列
% Cu = [1 0 0 0;
%     0 0 0 1];
% 
% Ae = [A_new  zeros(4,2);
%       -Cu    zeros(2,2)];
% 
% Be = [B_new;
%     zeros(2,3)];
% 
% % LQR ゲイン計算
% xu = [1, deg2rad(2), deg2rad(2), deg2rad(1.5)];  %
% Qx = diag(1./(xu.^2));
% 
% 
% xi = [10, deg2rad(15)];  
% Qi = 0.01 * diag(1./(xi.^2));
% Q = blkdiag(Qx, Qi);
% R  = [deg2rad(10) 0 0;
%       0 0.4 0;
%       0 0 0.15];
% 
% K = lqr(Ae, Be, Q, R);
% 
% Kx = K(:,1:4);
% Ki = K(:,5:6);
% 
% alpha0 = atan2(w0,u0);
% 
% hdot0 = (0.0603997403354420-alpha0)*V0;
% % シミュレーション実行
% simOut = sim('RCAM_non_linear.slx');
% Kx = K(:,1:4);
% Acl_pl  = A_new - B_new*Kx;     % 4x4（プラントのみ：SP/PH抽出に推奨）
% 
% 
% 
% % 線形化モデル
% [out] = sim("Copy_of_RCAM_LQI_with_PID_restored_from_autosave.slx");
% t = out.u.time;
% 
% u_n = out.u.data;
% u1 = u_n(:,1);
% u2 = u_n(:,2);
% 
% alpha_n = out.alpha.data;
% 
% 
% q_n = out.q.data;
% 
% 
% theta_n = out.theta.data;
% theta1 = theta_n(:,1);
% theta2 = theta_n(:,2);
% 
% h = out.h.data;
% h1 = h(:,1);
% h2 = h(:,2);
% figure;
% 
% 
% subplot(5,1,1); hold on; grid on;
% plot(t,u1,'-','LineWidth',2);
% plot(t,u2,'-.','LineWidth',2);
% xlabel('Time (s)','FontSize',15,'FontName','Times New roman');
% ylabel('Speed(m/s)','FontSize',15,'FontName','Times New roman');
% 
% subplot(5,1,2); hold on; grid on;
% plot(t,alpha_n,'-','LineWidth',2);
% xlabel('Time(s) ','FontSize',15,'FontName','Times New roman');
% ylabel('Angle of attack(deg)','FontSize',15,'FontName','Times New roman');
% 
% subplot(5,1,3); hold on; grid on;
% plot(t,q_n,'-','LineWidth',2);
% xlabel('Time (s)','FontSize',15,'FontName','Times New roman');
% ylabel('Pitch rate(deg/s)','FontSize',15,'FontName','Times New roman');
% 
% subplot(5,1,4); hold on; grid on;
% plot(t,theta1,'-','LineWidth',2);
% plot(t,theta2,'-.','LineWidth',2);
% xlabel('Time(s)','FontSize',15,'FontName','Times New roman');
% ylabel('Angle of pitch(deg)','FontSize',15,'FontName','Times New roman');
% 
% subplot(5,1,5); hold on; grid on;
% 
% plot(t,h1,'-','LineWidth',2);
% plot(t,h2,'-.','LineWidth',2);
% xlabel('Time(s)','FontSize',15,'FontName','Times New roman');
% ylabel('Altitude(m)','FontSize',15,'FontName','Times New roman');
% 
% axs = findall(gcf,'Type','axes');
% axs = flipud(axs);  % 上から順にしたい場合（必要なら）
% 
% labels = {'(a)','(b)','(c)','(d)','(e)'};
% 
% for k = 1:min(5,numel(axs))
%     ax = axs(k);
%     text(ax, 0.02, 0.88, labels{k}, ...
%         'Units','normalized', ...
%         'FontSize', 12, 'FontWeight','bold', ...
%         'VerticalAlignment','top', 'HorizontalAlignment','left');
% end
% 
% % 非線形モデル
% [out1] = sim("RCAM_non_linear.slx");
% 
% t1 = out1.u_n.time;
% 
% % --- signals (必ず(:)で列ベクトル化) ---
% 
% h_n = out1.h_n.data(:);     % ←実高度の信号名はあなたのモデルに合わせる
% u_n1     = out1.u_n.data(:,1);   % 例：uが2列なら1列目
% theta_n1 = out1.theta_n.data(:,1);
% 
% % トリム（例）
% u0 = 77.0813770383570;
% theta0 = 0.0604;
% 
% % --- time ---
% t = out1.h_n.time(:);
% 
% 
% u_n = out1.u_n.data;
% u1 = u_n(:,1);
% u2 = u_n(:,2);
% 
% alpha_n = out1.alpha_n.data;
% 
% 
% q_n = out1.q_n.data;
% 
% 
% theta_n = out1.theta_n.data;
% theta1 = theta_n(:,1);
% theta2 = theta_n(:,2);
% 
% 
% h_n = out1.h_n.data;
% h1 = h_n(:,1);
% h2 = h_n(:,2);
% figure;
% 
% subplot(5,1,1); hold on; grid on;
% plot(t,u1,'-','LineWidth',2);
% plot(t,u2,'-.','LineWidth',2);
% xlabel('Time (s)','FontSize',15,'FontName','Times New roman');
% ylabel('Speed(m/s)','FontSize',15,'FontName','Times New roman');
% 
% subplot(5,1,2); hold on; grid on;
% plot(t,alpha_n,'-','LineWidth',2);
% xlabel('Time(s) ','FontSize',15,'FontName','Times New roman');
% ylabel('Angle of attack(deg)','FontSize',15,'FontName','Times New roman');
% 
% subplot(5,1,3); hold on; grid on;
% plot(t,q_n,'-','LineWidth',2);
% xlabel('Time (s)','FontSize',15,'FontName','Times New roman');
% ylabel('Pitch rate(deg/s)','FontSize',15,'FontName','Times New roman');
% 
% subplot(5,1,4); hold on; grid on;
% plot(t,theta1,'-','LineWidth',2);
% plot(t,theta2,'-.','LineWidth',2);
% xlabel('Time(s)','FontSize',15,'FontName','Times New roman');
% ylabel('Angle of pitch(deg)','FontSize',15,'FontName','Times New roman');
% 
% subplot(5,1,5); hold on; grid on;
% 
% pSim = plot(t,h1,'-','LineWidth',2);
% pTgt = plot(t,h2,'-.','LineWidth',2);
% xlabel('Time(s)','FontSize',15,'FontName','Times New roman');
% ylabel('Altitude(m)','FontSize',15,'FontName','Times New roman');
% 
% axs = findall(gcf,'Type','axes');
% axs = flipud(axs);  % 上から順にしたい場合（必要なら）
% 
% labels = {'(a)','(b)','(c)','(d)','(e)'};
% 
% for k = 1:min(5,numel(axs))
%     ax = axs(k);
%     text(ax, 0.02, 0.88, labels{k}, ...
%         'Units','normalized', ...
%         'FontSize', 12, 'FontWeight','bold', ...
%         'VerticalAlignment','top', 'HorizontalAlignment','left');
% end

y = out.theta.signals.values;   % 出力
t = out.theta.time;             % 時間

yss = y(end);               % 最終値
A = abs(y - yss);

[pks,locs] = findpeaks(A,t);

A1 = pks(1);
A2 = pks(2);

delta = log(A1/A2);
zeta = delta/sqrt(4*pi^2 + delta^2);