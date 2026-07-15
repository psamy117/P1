%% BATCH ANNEALING FURNACE (H2 BAF) - HEAT TRANSFER MODEL
%
%  Built directly from: Fang, C-J. and Wu, L-W., "Batch Annealing Model for
%  Cold Rolled Coils and Its Application", China Steel Technical Report
%  No. 28, pp.13-20 (2015) - the HeatMod-based simulation model China
%  Steel Corporation developed for their 100% HYDROGEN batch annealing
%  furnace (H2 BAF). Equation numbers below refer to that paper.
%
%  GOVERNING EQUATIONS (as given in the paper):
%   Eq.1  Coil conduction (cylindrical coords, axisymmetric r-z plane):
%           rho*Cm*dTm/dtau = d/dz(kz*dTm/dz) + (1/r)*d/dr(r*kr*dTm/dr)
%         kr depends on sheet thickness and the air gap between wraps
%         (radial), kz is the coil's axial conductivity (along the strip
%         width direction - continuous solid steel, no wrap gaps that way).
%   Eq.2  Convection, gas <-> coil:      Q = A*alpha*(T1-T2)
%         - applies BOTH at the outer coil surface (facing the inner
%           cover) AND within the inner coil core/eye (the atmosphere
%           circulates through both paths, per Fig.2/Fig.4).
%   Eq.3  Gas-side transport:            Q = Mdot*Cp*(Tin-Tout)
%         - the paper tracks an OUTER gas stream (in the annulus, heated
%           by the cover) and an INNER gas stream (through the coil eyes),
%           and gets the LOCAL gas temperature at the convector plate (the
%           coil's top/bottom faces) by INTERPOLATING radially between the
%           inner and outer stream temperatures.
%   Eq.4  Radiation, cover <-> coil OD:  Q = A*F*eps*sigma*(Tcover^4-Tsurf^4)
%         - implemented here in the algebraically identical LINEARISED
%           form h_rad*(Tcover-Tsurf), h_rad = eps*sigma*(Tc^2+Ts^2)*(Tc+Ts).
%
%  CONTROL LOGIC (Fig.5 flowcharts), reproduced as closely as a script
%  reasonably can:
%   (a) HEATING: each time step, the gas temperature is driven to match a
%       given set-point (the paper's "vary heating capacity ... until gas
%       temperature = set-point" inner loop) - so the outer gas
%       temperature is treated here as a PRESCRIBED ramp-then-hold
%       schedule (this is exactly what "vary capacity until it matches
%       set-point" means for a lumped gas node: it reaches the set-point).
%       Heating ends when the COLD SPOT (paper's term for the
%       slowest-heating point in the coil - NOT the base/cover
%       temperature, which the paper found is 17-46 C removed from the
%       true cold spot) exceeds the set-point in every stack.
%   (b) COOLING: burner off: temperatures are recalculated each step, coil
%       conduction solved, and IF the gas temperature drops below a
%       "setpoint - rapid cooling" trigger, the heat-transfer parameters
%       change (circulation is stepped up - a cooling-hood/rapid-cool
%       switch). Cooling ends when the coil cold spot OR the base
%       temperature drops below a target (an OR condition, exactly as
%       drawn in Fig.5b).
%
%  WHAT IS NOT IN THE PAPER (and is therefore NOT modelled here): the
%  paper never publishes its combustion/burner sub-model, its exact
%  convection correlation, or numeric values for kr, alpha, Mdot etc. -
%  those are proprietary HeatMod internals. Anywhere this script needs a
%  number the paper doesn't give, it uses a clearly labelled engineering
%  estimate under "ADVANCED PARAMETERS" - edit these if you have
%  plant/HeatMod data.
%
%  Atmosphere: 100% HYDROGEN (a true H2 BAF, per the paper - NOT the older
%  HNx mix of ~7% H2/93% N2 their model was originally derived from). All
%  gas properties below are pure-H2 correlations.
%
%  USER INPUTS: each of the 5 stacked coils gets its own strip thickness,
%  width and annealing (soak) target, prompted coil-by-coil below. A
%  single furnace-wide HEATING RATE [C/hr] is also requested (the paper's
%  introduction names this, alongside soak temperature, as a first-order
%  recipe/metallurgy parameter). Furnace height is fixed at 7 m, 5 coils
%  stacked, per the given furnace design.
%
%  Requires: base MATLAB only (ode15s) - no toolboxes.
%
%  Figures are saved to a "furnace_results" folder next to this script
%  (PNG + editable FIG) and the script pauses at the end waiting for
%  Enter, so results survive even if launched in a way that auto-exits
%  MATLAB right after the script finishes.
%
%  NOTE: this script does NOT close any pre-existing figure windows, so
%  results from earlier runs (e.g. with different coil inputs) stay on
%  screen for comparison. Close old figure windows yourself if you want a
%  clean slate before the next run.

clear; clc;

%% =====================================================================
%  1) FURNACE / STACK GEOMETRY (fixed by problem statement)
%  =====================================================================
furnace_height_m = 7.0;
n_coils          = 5;

%% =====================================================================
%  2) USER INPUTS
%  =====================================================================
default_thk_mm = [0.30 0.50 0.70 1.00 1.20];
default_wid_mm = [1000 1100 1200 1000  900];
default_tgt_C  = [680  700  700  720  690];

thickness_mm = zeros(1,n_coils);
width_mm     = zeros(1,n_coils);
T_anneal_C   = zeros(1,n_coils);

for c = 1:n_coils
    fprintf('\n-- Coil %d of %d (stack position, base -> top) --\n', c, n_coils);
    v = input(sprintf('  Strip thickness [mm] (default %.2f): ', default_thk_mm(c)));
    if isempty(v), v = default_thk_mm(c); end
    thickness_mm(c) = v;

    v = input(sprintf('  Coil width [mm] (default %.0f): ', default_wid_mm(c)));
    if isempty(v), v = default_wid_mm(c); end
    width_mm(c) = v;

    v = input(sprintf('  Annealing (soak) temperature [C] (default %.0f): ', default_tgt_C(c)));
    if isempty(v), v = default_tgt_C(c); end
    T_anneal_C(c) = v;
end

fprintf('\n--- Inputs summary ---\n');
fprintf(' Coil | Thickness[mm] | Width[mm] | Target[C]\n');
for c = 1:n_coils
    fprintf('  %2d  |     %5.2f     |   %5.0f   |   %5.0f\n', ...
        c, thickness_mm(c), width_mm(c), T_anneal_C(c));
end

default_heating_rate_C_per_hr = 40;
v = input(sprintf('\nFurnace heating (ramp) rate [deg C/hr] (default %.0f): ', default_heating_rate_C_per_hr));
if isempty(v), v = default_heating_rate_C_per_hr; end
heating_rate_C_per_hr = v;
fprintf('Heating rate set to %.1f C/hr\n\n', heating_rate_C_per_hr);

thickness_m = thickness_mm/1000;
width_m     = width_mm/1000;

%% =====================================================================
%  3) ADVANCED PARAMETERS - not published in the source paper; edit if
%     you have plant/HeatMod data.
%  =====================================================================

% --- Coil geometry / material ---------------------------------------
coil_ID_m      = 0.850;     % coil eye (inner bore) diameter, same for all coils
coil_mass_kg   = 20000;     % steel mass per coil (typical ~20 t coil)
rho_steel      = 7850;      % kg/m^3
cp_steel       = 490;       % J/kg/K
k_steel        = 45;        % W/m/K (solid steel conductivity)

% kr (Eq.1's radial conductivity, "depends on sheet thickness and air gap
% between sheets" per the paper - exact form is cited to a separate
% reference, not given numerically here). Series-resistance estimate:
%   1/kr = 1/k_steel + R_contact/thickness
% thinner strip -> more wrap interfaces per metre of radius -> lower kr.
R_contact = 2.2e-4;    % m^2.K/W, wrap-to-wrap contact resistance (typical
                       % range 1e-4 - 5e-4)
kr = 1./(1/k_steel + R_contact./thickness_m);     % 1 x n_coils

% kz (Eq.1's axial conductivity): the coil's axial direction runs along
% the strip WIDTH, which is continuous solid steel with no wrap-to-wrap
% air gaps - so kz is taken as the bulk steel conductivity.
kz = k_steel;

eps_coil  = 0.55;   % coil (steel strip) surface emissivity
eps_cover = 0.80;   % oxidised inner-cover emissivity
eps_eff   = 1/(1/eps_cover + 1/eps_coil - 1);   % Eq.4's eps*F, parallel-plate estimate
sigma_SB  = 5.670374e-8;

% Coil OD back-calculated per coil from fixed mass, common ID and own width:
r_ID = coil_ID_m/2;
OD_m = sqrt(coil_ID_m^2 + 4*coil_mass_kg./(pi*rho_steel*width_m));   % 1 x n_coils

fprintf('Derived per-coil geometry:\n');
fprintf(' Coil |  OD[m] | kr[W/m/K]\n');
for c = 1:n_coils
    fprintf('  %2d  | %5.3f  |   %5.3f\n', c, OD_m(c), kr(c));
end
fprintf('\n');

% --- Furnace shell / cooling-stand heat rejection (COOL phase only) ---
% In practice the load is moved onto (or a cooling hood/jacket replaces
% the heating hood on) a dedicated cooling stand for this stage - a
% passive-insulated-shell loss coefficient (a few W/m^2/K) would make
% cooling take days (checked: >200 h), which does not match real batch-
% anneal cool-down durations of roughly 1-2 days. U_cool below represents
% that stand's heat rejection, not bare shell insulation loss.
gap_annulus_m = 0.30;
D_shell_m     = max(OD_m) + 2*gap_annulus_m;
A_shell_lat   = pi*D_shell_m*furnace_height_m;
U_cool        = 15.0;   % W/m^2/K, cooling-stand heat rejection coefficient
T_amb_C       = 25;

% --- Convection coefficients (Eq.2) - the paper does not publish its
% correlation; these are engineering-typical values for H2 BAF forced
% convection, applied uniformly at each boundary.
h_ID   = 70;   % W/m^2/K, coil inner-core (eye) face
h_OD   = 90;   % W/m^2/K, coil outer surface (faces the cover)
h_face = 60;   % W/m^2/K, coil top/bottom faces (face the convector plates)

% --- Gas-side transport (Eq.3) ----------------------------------------
Q_fan_m3s = 3.0;          % total circulation flow, actual m^3/s
P_furnace_Pa = 1.05*101325;
M_H2  = 2.016e-3;         % kg/mol
Rg    = 8.314;            % J/mol/K
cp_H2 = 14300;            % J/kg/K (100% H2 atmosphere)

hood_margin_C = 30;   % during HEAT/SOAK the inner cover runs this many
                       % degrees above the (controlled) outer gas
                       % temperature - a necessary simplification since
                       % the paper does not publish a separate cover
                       % energy balance; it only states the burner
                       % capacity is varied each step until the GAS
                       % temperature matches its set-point.

% --- Radial x axial FD mesh, per coil ---------------------------------
Nr = 10;
Nz = 5;

% --- Cycle control ------------------------------------------------------
tol_C             = 5;    % "at temperature" tolerance
soak_time_hr      = 6;    % hold time once every cold spot reaches target
cool_target_C     = 100;  % cooling ends when cold spot OR base temp < this
rapid_cool_trigger_C  = 400;    % Fig.5b: "gas temp < setpoint - rapid cooling"
rapid_cool_fan_factor = 1.8;    % circulation step-up once triggered
rapid_cool_uloss_factor = 3.0;  % cooling-stand heat rejection step-up once
                                % triggered (e.g. forced water spray engaging)
heat_search_hr = 150;   % safety cap on the heating-stage event search
cool_search_hr = 150;   % safety cap on the cooling-stage event search

%% =====================================================================
%  4) CHECK STACK HEIGHT FITS THE 7 m FURNACE
%  =====================================================================
base_stand_m = 0.5; plate_gap_m = 0.08; top_clear_m = 0.8;
stack_height_m = base_stand_m + sum(width_m) + (n_coils-1)*plate_gap_m + top_clear_m;
fprintf('Stack height required: %.2f m (furnace = %.1f m)\n', stack_height_m, furnace_height_m);
if stack_height_m > furnace_height_m
    warning('Requested coil widths leave the stack %.2f m TALLER than the 7 m furnace. Reduce widths.', ...
        stack_height_m-furnace_height_m);
else
    fprintf('OK - stack fits with %.2f m clearance.\n\n', furnace_height_m-stack_height_m);
end

%% =====================================================================
%  5) BUILD PER-COIL 2D (r,z) FINITE-DIFFERENCE GEOMETRY (Eq.1 grid)
%  =====================================================================
r_edges_all = zeros(n_coils, Nr+1);
r_cen_all   = zeros(n_coils, Nr);
Area_i      = zeros(n_coils, Nr);   % annular cross-sectional area at radial index i
C_th        = zeros(n_coils, Nr);   % thermal capacitance per layer, at radial index i
Gr          = zeros(n_coils, Nr-1); % radial conductance i<->i+1
Gz          = zeros(n_coils, Nr);   % axial conductance at radial index i, between layers
A_ID_face   = zeros(n_coils,1);
A_OD_face   = zeros(n_coils,1);
G_facetb    = zeros(n_coils, Nr);   % top/bottom boundary conductance at radial index i
frac_r      = zeros(n_coils, Nr);   % (r_cen-r_ID)/(r_OD-r_ID), for Eq.3's radial interpolation
dz_c        = zeros(n_coils,1);

for c = 1:n_coils
    r_OD = OD_m(c)/2;
    r_edges = linspace(r_ID, r_OD, Nr+1);
    r_cen   = 0.5*(r_edges(1:end-1) + r_edges(2:end));
    r_edges_all(c,:) = r_edges;
    r_cen_all(c,:)   = r_cen;
    frac_r(c,:) = (r_cen - r_ID)/(r_OD - r_ID);

    dz = width_m(c)/Nz;
    dz_c(c) = dz;

    Ai = pi*(r_edges(2:end).^2 - r_edges(1:end-1).^2);   % 1 x Nr
    Area_i(c,:) = Ai;
    C_th(c,:)   = rho_steel*cp_steel*Ai*dz;

    A_r_face = 2*pi*r_edges(2:end-1)*dz;     % Nr-1 internal radial interfaces
    dr_cen   = diff(r_cen);
    Gr(c,:)  = kr(c)*A_r_face./dr_cen;

    Gz(c,:) = kz*Ai/dz;

    A_ID_face(c) = 2*pi*r_ID*dz;
    A_OD_face(c) = 2*pi*r_OD*dz;
    G_facetb(c,:) = h_face*Ai;
end

%% =====================================================================
%  6) PARAMETER STRUCT + INITIAL CONDITIONS
%     State = coil temperatures ONLY (Nr x Nz x n_coils). Gas/cover
%     temperatures are NOT separate ODE states - consistent with the
%     paper's scheme, where they are solved/converged algebraically each
%     time step (the "vary heating capacity until set-point matched"
%     inner loop), and only the coil conduction is genuinely dynamic.
%  =====================================================================
T0_C = T_amb_C;
y0 = T0_C*ones(Nr*Nz*n_coils,1);

p = struct('Nr',Nr,'Nz',Nz,'n_coils',n_coils, ...
    'Gr',Gr,'Gz',Gz,'C_th',C_th,'A_ID_face',A_ID_face,'A_OD_face',A_OD_face, ...
    'G_facetb',G_facetb,'frac_r',frac_r,'h_ID',h_ID,'h_OD',h_OD, ...
    'eps_eff',eps_eff,'sigma_SB',sigma_SB,'T_amb_C',T_amb_C,'U_cool',U_cool, ...
    'A_shell_lat',A_shell_lat,'Q_fan_m3s',Q_fan_m3s,'P_furnace_Pa',P_furnace_Pa, ...
    'M_H2',M_H2,'Rg',Rg,'cp_H2',cp_H2,'hood_margin_C',hood_margin_C, ...
    'heating_rate_C_per_hr',heating_rate_C_per_hr,'T_gas_ceiling_C',max(T_anneal_C), ...
    'T_anneal_C',T_anneal_C,'tol_C',tol_C,'rapid_cool_trigger_C',rapid_cool_trigger_C, ...
    'rapid_cool_fan_factor',rapid_cool_fan_factor,'rapid_cool_uloss_factor',rapid_cool_uloss_factor, ...
    'cool_target_C',cool_target_C, ...
    'phase','heat','t_offset_s',0);

%% =====================================================================
%  7) STAGE A - HEATING (Fig.5a): ends when every coil's COLD SPOT
%     exceeds its own set-point
%  =====================================================================
opts_heat = odeset('RelTol',1e-6,'AbsTol',1e-4, 'Events', @(t,y) cold_spot_event(t,y,p));
t_span_A = linspace(0, heat_search_hr*3600, 600);
[tA, YA, teA] = ode15s(@(t,y) furnace_odes(t,y,p), t_span_A, y0, opts_heat);
if isempty(teA)
    warning('Not all coils'' cold spots reached target within the %.0f h search horizon.', heat_search_hr);
end
t_heat_end = tA(end);

%% =====================================================================
%  8) STAGE B - SOAK: hold at the same (already-reached) gas set-point
%  =====================================================================
% Stage B's local ODE time resets to 0, but the heating-ramp schedule
% needs cumulative time since heating started - carry that forward via
% t_offset_s so the gas set-point doesn't reset back toward ambient.
p_soak = p;
p_soak.t_offset_s = t_heat_end;
t_span_B = linspace(0, soak_time_hr*3600, 150);
opts_soak = odeset('RelTol',1e-6,'AbsTol',1e-4);
[tB, YB] = ode15s(@(t,y) furnace_odes(t,y,p_soak), t_span_B, YA(end,:)', opts_soak);

%% =====================================================================
%  9) STAGE C - COOLING (Fig.5b): ends when cold spot OR base temp drops
%     below cool_target_C; rapid-cool switch engages internally.
%  =====================================================================
p_cool = p; p_cool.phase = 'cool';
opts_cool = odeset('RelTol',1e-6,'AbsTol',1e-4, 'Events', @(t,y) cooling_done_event(t,y,p_cool));
t_span_C = linspace(0, cool_search_hr*3600, 600);
[tC, YC, teC] = ode15s(@(t,y) furnace_odes(t,y,p_cool), t_span_C, YB(end,:)', opts_cool);
if isempty(teC)
    warning('Cooling did not reach the %.0f C target within the %.0f h search horizon.', cool_target_C, cool_search_hr);
end

%% =====================================================================
%  10) STITCH STAGES INTO ONE FULL-CYCLE TIME HISTORY
%  =====================================================================
t_soak_end = t_heat_end + tB(end);
t_total    = t_soak_end + tC(end);

t = [tA; t_heat_end + tB(2:end); t_soak_end + tC(2:end)];
Y = [YA; YB(2:end,:); YC(2:end,:)];
t_hr = t/3600;
nT = length(t);

T = reshape(Y, nT, Nr, Nz, n_coils);
cold_spot = squeeze(min(min(T,[],2),[],3));   % nT x n_coils
hot_spot  = squeeze(max(max(T,[],2),[],3));   % nT x n_coils

% Recover gas/cover temperature history (algebraic each step, not a state)
T_outer = zeros(nT,1); T_inner = zeros(nT,1); T_cover = zeros(nT,1);
rapid_cool_active = false(nT,1);
for k = 1:nT
    Tk = squeeze(T(k,:,:,:));
    if t(k) <= t_soak_end
        % t(k) is already the cumulative time since heating started (the
        % stitched array), so t_offset_s=0 here gives the right ramp value.
        pk = p; pk.phase = 'heat'; pk.t_offset_s = 0;
        [T_outer(k), T_cover(k), T_inner(k), rapid_cool_active(k)] = solve_gas_temps(t(k), Tk, pk);
    else
        [T_outer(k), T_cover(k), T_inner(k), rapid_cool_active(k)] = solve_gas_temps(t(k)-t_soak_end, Tk, p_cool);
    end
end

%% =====================================================================
%  11) RESULTS SUMMARY
%  =====================================================================
fprintf('\n--- Results ---\n');
for c = 1:n_coils
    idx = find(cold_spot(:,c) >= T_anneal_C(c) - tol_C, 1, 'first');
    if isempty(idx)
        fprintf('Coil %d: cold spot did NOT reach its %.0f C target within the simulated cycle\n', c, T_anneal_C(c));
    else
        fprintf('Coil %d: cold spot reaches its %.0f C target at t = %.1f h (hot spot was %.0f C)\n', ...
            c, T_anneal_C(c), t_hr(idx), hot_spot(idx,c));
    end
end
fprintf('\nHeat-up complete           : %.1f h\n', t_heat_end/3600);
fprintf('Annealing time (heat+soak) : %.1f h\n', t_soak_end/3600);
idx_rapid = find(rapid_cool_active, 1, 'first');
if isempty(idx_rapid)
    fprintf('Rapid cooling              : never triggered\n');
else
    fprintf('Rapid cooling engaged at t = %.1f h (gas < %.0f C, fan flow x%.1f)\n', ...
        t_hr(idx_rapid), rapid_cool_trigger_C, rapid_cool_fan_factor);
end
fprintf('Cooling complete           : %.1f h (cold spot or base < %.0f C)\n', tC(end)/3600, cool_target_C);
fprintf('Total cycle time           : %.1f h\n', t_total/3600);
fprintf('\nRequested furnace heating rate: %.1f C/hr\n', heating_rate_C_per_hr);
for c = 1:n_coils
    fprintf('Coil %d effective avg. cold-spot heating rate: %.1f C/hr\n', ...
        c, (T_anneal_C(c)-T_amb_C)/(t_heat_end/3600));
end

%% =====================================================================
%  12) FULL-CYCLE GRAPH
%  =====================================================================
fig1 = figure('Name','Full Annealing Cycle','Color','w','Position',[100 100 900 900]);

ax1 = subplot(3,1,1);
plot(t_hr, T_cover, 'r-', 'LineWidth', 1.6); hold on;
plot(t_hr, T_outer, 'b-', 'LineWidth', 1.6);
plot(t_hr, T_inner, 'Color',[0 0.6 0.3], 'LineWidth', 1.4);
ylabel('Temp [C]');
legend('Cover (inner cover)','Outer gas (annulus)','Inner gas (coil eye)','Location','SouthEast');
title('Full Annealing Cycle: Heat-up -> Soak -> Cool'); grid on;

ax2 = subplot(3,1,2);
plot(t_hr, cold_spot, 'LineWidth', 1.5); hold on;
for c = 1:n_coils
    plot(xlim, [T_anneal_C(c) T_anneal_C(c)], '--', 'Color', [0.5 0.5 0.5], 'HandleVisibility','off');
end
ylabel('Cold spot [C]');
legend(arrayfun(@(c) sprintf('Coil %d',c), 1:n_coils, 'UniformOutput', false), 'Location','SouthEast');
title('Coil COLD SPOT Temperature (min over full r-z grid)'); grid on;

ax3 = subplot(3,1,3);
plot(t_hr, hot_spot, 'LineWidth', 1.5);
xlabel('Time [h]'); ylabel('Hot spot [C]');
legend(arrayfun(@(c) sprintf('Coil %d',c), 1:n_coils, 'UniformOutput', false), 'Location','SouthEast');
title('Coil HOT SPOT Temperature (max over full r-z grid)'); grid on;

for axh = [ax1 ax2 ax3]
    yl = get(axh,'YLim');
    hold(axh,'on');
    plot(axh, [t_heat_end t_heat_end]/3600, yl, 'k:', 'HandleVisibility','off');
    plot(axh, [t_soak_end t_soak_end]/3600, yl, 'k:', 'HandleVisibility','off');
    if ~isempty(idx_rapid)
        plot(axh, [t_hr(idx_rapid) t_hr(idx_rapid)], yl, 'c:', 'LineWidth', 1.2, 'HandleVisibility','off');
    end
    set(axh,'YLim',yl);
end
linkaxes([ax1 ax2 ax3],'x');

%% =====================================================================
%  13) SUPPLEMENTARY: 2D (r,z) TEMPERATURE FIELD, COIL 1, END OF SOAK
%  =====================================================================
fig2 = figure('Name','Coil 2D Temperature Field (end of soak)','Color','w');
[~, k_soak] = min(abs(t_hr - t_soak_end/3600));
Tfield = squeeze(T(k_soak,:,:,1));           % Nr x Nz
z_cen = ((1:Nz)-0.5)*dz_c(1);
contourf((r_cen_all(1,:)-r_ID)*1000, z_cen*1000, Tfield', 20, 'LineStyle','none');
colorbar; colormap('turbo');
xlabel('Radial distance from coil ID [mm]'); ylabel('Axial position from base of coil [mm]');
title(sprintf('Coil 1: 2D Temperature Field at End of Soak [C] (t=%.1f h)', t_hr(k_soak)));

%% =====================================================================
%  14) SAVE FIGURES TO DISK
%  =====================================================================
drawnow;
outdir = fullfile(pwd, 'furnace_results');
if ~exist(outdir, 'dir'), mkdir(outdir); end
run_tag = datestr(now, 'yyyymmdd_HHMMSS');   %#ok<TNOW1,DATST> % unique per run, so repeat runs don't overwrite each other's saved files
saveas(fig1, fullfile(outdir, ['full_annealing_cycle_' run_tag '.png']));
saveas(fig2, fullfile(outdir, ['coil_2d_temperature_field_' run_tag '.png']));
saveas(fig1, fullfile(outdir, ['full_annealing_cycle_' run_tag '.fig']));
saveas(fig2, fullfile(outdir, ['coil_2d_temperature_field_' run_tag '.fig']));
fprintf('\nFigures saved to: %s (tagged %s)\n', outdir, run_tag);

% In non-interactive execution (matlab -batch, many online/cloud MATLAB
% runners, CI) there is no persistent desktop to keep alive - the session
% tears down the instant the script returns, and input() itself throws an
% error in that mode. Catch that so the run still ends cleanly instead of
% erroring out; the PNG/FIG files above are the real deliverable there.
try
    input('\nPress Enter in this window to close... (figures are already saved to disk above)', 's');
catch
    fprintf('\n(Non-interactive session detected - skipping the pause. Open the PNG/FIG files in %s to view the results.)\n', outdir);
end

%% =====================================================================
%  LOCAL FUNCTIONS
%  =====================================================================
function dydt = furnace_odes(t, y, p)
    Nr = p.Nr; Nz = p.Nz; nC = p.n_coils;
    T = reshape(y, Nr, Nz, nC);

    [T_outer, T_cover, T_inner] = solve_gas_temps(t, T, p);

    Tsurf_OD = squeeze(T(Nr,:,:));   % Nz x nC
    Tc_K = T_cover + 273.15; Ts_K = Tsurf_OD + 273.15;
    h_rad = p.eps_eff*p.sigma_SB*(Tc_K^2+Ts_K.^2).*(Tc_K+Ts_K);   % Nz x nC, Eq.4 linearised

    dT = zeros(Nr,Nz,nC);
    for c = 1:nC
        for j = 1:Nz
            T_gas_local = T_inner + (T_outer-T_inner)*p.frac_r(c,:);   % 1 x Nr, Eq.3 interpolation
            for i = 1:Nr
                acc = 0;
                if i > 1,  acc = acc + p.Gr(c,i-1)*(T(i-1,j,c)-T(i,j,c)); end
                if i < Nr, acc = acc + p.Gr(c,i)  *(T(i+1,j,c)-T(i,j,c)); end
                if j > 1,  acc = acc + p.Gz(c,i)*(T(i,j-1,c)-T(i,j,c)); end
                if j < Nz, acc = acc + p.Gz(c,i)*(T(i,j+1,c)-T(i,j,c)); end
                if i == 1
                    acc = acc + p.h_ID*p.A_ID_face(c)*(T_inner - T(i,j,c));
                end
                if i == Nr
                    acc = acc + p.h_OD*p.A_OD_face(c)*(T_outer - T(i,j,c)) ...
                              + p.A_OD_face(c)*h_rad(j,c)*(T_cover - T(i,j,c));
                end
                if j == 1 || j == Nz
                    acc = acc + p.G_facetb(c,i)*(T_gas_local(i) - T(i,j,c));
                end
                dT(i,j,c) = acc / p.C_th(c,i);
            end
        end
    end
    dydt = dT(:);
end

function [T_outer, T_cover, T_inner, rapid_active] = solve_gas_temps(t, T, p)
    % Algebraic (quasi-steady) solve for the two gas streams + cover, per
    % time step - matches the paper's "temperature calculation" step,
    % converged against a set-point during heating, or against the
    % ambient/coil balance during cooling.
    Nz = p.Nz; nC = p.n_coils;
    Tsurf_OD = squeeze(T(p.Nr,:,:));   % Nz x nC
    T_ID     = squeeze(T(1,:,:));      % Nz x nC

    Q_fan = p.Q_fan_m3s;
    rapid_active = false;

    if strcmp(p.phase,'cool')
        % Quasi-steady balance: heat given up by coil ODs (+ radiation,
        % using a first-pass cover-temperature guess) is lost to the
        % cooling stand - this replaces the burner as the driving term
        % once it is switched off. First pass with the baseline rejection
        % coefficient; if that already implies gas below the rapid-cool
        % trigger, re-solve with the boosted coefficient (Fig.5b switch).
        T_outer = cool_T_outer_balance(Tsurf_OD, p, p.U_cool);
        if T_outer < p.rapid_cool_trigger_C
            Q_fan = Q_fan*p.rapid_cool_fan_factor;
            T_outer = cool_T_outer_balance(Tsurf_OD, p, p.U_cool*p.rapid_cool_uloss_factor);
            rapid_active = true;
        end
        T_cover = T_outer;
    else
        % HEAT/SOAK: gas temperature is driven to its set-point each step
        % (the paper's inner "vary heating capacity" loop) - so it is a
        % prescribed ramp-then-hold schedule, capped at the highest
        % coil's own annealing target.
        t_elapsed_hr = (t + p.t_offset_s)/3600;   % cumulative time since start of heating
        T_outer = min(p.T_amb_C + p.heating_rate_C_per_hr*t_elapsed_hr, p.T_gas_ceiling_C);
        T_outer = max(T_outer, p.T_amb_C);
        T_cover = T_outer + p.hood_margin_C;
    end

    % Inner gas stream via Eq.3's mass-flow energy balance: it cools from
    % T_outer (its inlet, after recirculating) as it gives up heat to
    % every coil's ID face on its way through the stack.
    T_guess_K = mean([T_outer; T_ID(:)]) + 273.15;
    rho_g = h2_density(T_guess_K, p.P_furnace_Pa, p.M_H2, p.Rg);
    Mdot = rho_g*Q_fan;

    sum_AT_ID = 0; total_A_ID = 0;
    for c = 1:nC
        sum_AT_ID  = sum_AT_ID  + p.A_ID_face(c)*sum(T_ID(:,c));
        total_A_ID = total_A_ID + p.A_ID_face(c)*Nz;
    end
    T_inner = (Mdot*p.cp_H2*T_outer + p.h_ID*sum_AT_ID) / (Mdot*p.cp_H2 + p.h_ID*total_A_ID);
end

function [value, isterminal, direction] = cold_spot_event(t, y, p)
    Nr = p.Nr; Nz = p.Nz; nC = p.n_coils;
    T = reshape(y, Nr, Nz, nC);
    cold = squeeze(min(min(T,[],1),[],2));   % 1 x nC
    value = max(p.T_anneal_C - p.tol_C - cold(:)');   % >0 until slowest coil catches up
    isterminal = 1;
    direction = -1;
end

function [value, isterminal, direction] = cooling_done_event(t, y, p)
    Nr = p.Nr; Nz = p.Nz; nC = p.n_coils;
    T = reshape(y, Nr, Nz, nC);
    cold_max = max(squeeze(min(min(T,[],1),[],2)));
    [T_outer, ~, ~] = solve_gas_temps(t, T, p);
    % Fig.5b OR condition: stop once EITHER cold spot OR base/outer temp
    % drops below the cooling target.
    value = min(cold_max, T_outer) - p.cool_target_C;
    isterminal = 1;
    direction = -1;
end

function rho_g = h2_density(T_K, P_Pa, M, Rg)
    % 100% H2, ideal gas law.
    rho_g = P_Pa*M/(Rg*T_K);
end

function T_outer = cool_T_outer_balance(Tsurf_OD, p, U_eff)
    % Quasi-steady outer-gas/cover balance during cooling: heat given up
    % by all coils' OD faces (convection + radiation, using a mean-surface
    % cover-temperature guess for the radiation linearisation) equals heat
    % rejected to the cooling stand at coefficient U_eff.
    nC = p.n_coils;
    Tc_guess_K = mean(Tsurf_OD(:)) + 273.15;
    Ts_K = Tsurf_OD + 273.15;
    h_rad_guess = p.eps_eff*p.sigma_SB*(Tc_guess_K^2+Ts_K.^2).*(Tc_guess_K+Ts_K);

    weighted = 0; total_cond = 0;
    for c = 1:nC
        g = (p.h_OD + h_rad_guess(:,c)) * p.A_OD_face(c);   % Nz x 1
        weighted   = weighted + sum(g.*Tsurf_OD(:,c));
        total_cond = total_cond + sum(g);
    end
    T_outer = (U_eff*p.A_shell_lat*p.T_amb_C + weighted) / (U_eff*p.A_shell_lat + total_cond);
end
