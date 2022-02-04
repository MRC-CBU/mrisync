function [resptime,respnumber,daqret] = scansync(ind,waituntil,opt)
% synchronise with volume acquisition trigger pulses and record button
% presses from CBU National Instruments MRI scanner interface.
%
% We support a crude emulation mode (a pretend trigger is sent every tr
% seconds, pretend buttonbox presses are logged on keyboard keys [v,b,n,m]
% and [f,d,s,a]), which is triggered automatically whenever the NI box
% cannot be detected.
%
% The first time you use this function in a session, you must initialise it
% with a special call syntax as described below. After that the call syntax
% is as in the inputs/outputs section.
%
% INITIALISATION:
% scansync('reset', tr) % where tr is repetition time in seconds
%
% STOPPING:
% It is advised to add this line at the end of your script
% It will clear the task and release the device
% scansync('stop');
%
% INPUTS:
% ind: array specifying which channel indices to check (in 1:9 range).
%   Default [], which means that the function waits for the below duration
%   while logging all responses. If a response occurs on any indexed
%   channel the function returns immediately.
% waituntil: optional timestamp to wait until before returning. Default 0,
%   which means check once and return. NB raw time stamps, so to wait 2s,
%   enter GetSecs+2.
% opt: additional options. Currently only 'waitrelease', to wait for any
%   buttons to be released before continuing
%
% OUTPUTS:
% resptime: array of response time for each channel specified in input ind,
%   or NaN if no response was received on that channel. Raw time stamps
%   from psychtoolbox (see GetSecs).
% respnumber: estimated current volume. Note that this is only a time / tr
%   dead reckoning operation. We do not make any attempt to track actual
%   TR.
% daqret: struct with internal state. Mainly useful for debugging and
%   advanced use cases (see example below).
%
%
% EXAMPLES:
% % Initialise a scansync session
% tr = 2; % TR in s
% scansync('reset',tr);
%
% % Wait for the first volume trigger (e.g. at start of run), and return
% % the time stamp when that happened.
% start_time = scansync(1,Inf);
%
% % Wait for 4s OR return early if the index-finger button on the right is
% % pressed (button_time will be NaN if there is no press)
% button_time = scansync(2,GetSecs+4); % absolute time stamps
%
% % Wait for the next volume trigger, return its time stamp and estimated number
% [triggertime, triggernum] = scansync(1,Inf);
%
% % Wait 2s no matter what (but keep track of all responses)
% [~, ~, daqstate] = scansync([],GetSecs+2);
%
% % Time stamp for last scanner pulse, which may have occurred during % the 2s interval
% in the example above.
% lastpulse_time = daqstate.lastresp(1);
%
% % Wait for buttons to be released before continuing
%   scansync(2,Inf,'waitrelease'); % will wait infinit time until channel 2
%   button is released
%   scansync_tmp(2,GetSecs+10,'waitrelease'); % will wait for 10s until button
%   is released. If not released will move on anyway.
%
% 2017-04-13 J Carlin, MRC CBU.
% 2019-06-19 Added support for two-handed mode
% 2019-10-02 Documentation, respnumber is scalar return
% 2020-09-21 Switch to undocumented NI API for performance
%
% Dace Apsvalka edits
% 2021-11-10 A new button press is counted only if the button goes from OFF to
%            ON (before it depended on predefined pulse duration)
% 2021-11-10 - Added an option to wait for buttons to be released.
% 2021-12-02 - Added scansync('stop') option to release the device. 

persistent daqstate

%+++++++++++++++++++++++++++++
% Stopping the task
%+++++++++++++++++++++++++++++
if ~isempty(daqstate) && strcmpi(ind,'stop')
    disp('Stopping the task')
    status = daq.ni.NIDAQmx.DAQmxStopTask(daqstate.hand);
    daq.ni.utility.throwOrWarnOnStatus(status);
    disp('Task stopped')
    return
end
if isempty(daqstate) && strcmpi(ind,'stop')
    disp('Nothing to stop')
    return    
end
%+++++++++++++++++++++++++++++
% Input check
%+++++++++++++++++++++++++++++
if ~exist('ind','var')
    ind = [];
end
if ~exist('waituntil','var') || isempty(waituntil) || isnan(waituntil)
    waituntil = 0;
end
assert(~isinf(waituntil) || ~isempty(ind), ...
    'unspecified channel index must be combined with finite waituntil duration')

if isempty(daqstate) && ~strcmpi(ind,'reset')
    error('You must initialise the session first! See the documentation.');
end
% /+++++++++++++++++++++++++++

%+++++++++++++++++++++++++++++
% Initialising
%+++++++++++++++++++++++++++++
if ischar(ind) && strcmpi(ind,'reset')
    % don't handle conflicting inputs
    assert(waituntil~=0, 'must set tr as second arg in reset mode');
    % special case to handle re-initialising sync
    if ~isempty(daqstate)
        status = daq.ni.NIDAQmx.DAQmxClearTask(daqstate.hand);
        daq.ni.utility.throwOrWarnOnStatus(status);
    end
    daqstate = [];
    ind = [];
end

if isempty(daqstate) && ~strcmpi(ind,'stop')
    % special initialisation mode
    fprintf('initialising...\n');
    tr = waituntil;
    % ordinarily infinite wait durations are fine, but not if you're
    % initialising a new session
    assert(~isinf(tr) && isscalar(tr),'tr must be finite, numeric, scalar');
    % check for DAQ
    daqstate.tr = tr;
    % input channels in order scanner pulse, buttonbox 1, buttonbox 2
    daqstate.channels = {...
        '/dev1/port0/line0', ...
        '/dev1/port0/line1', ...
        '/dev1/port0/line2', ...
        '/dev1/port0/line3', ...
        '/dev1/port0/line4', ...
        '/dev1/port0/line5', ...
        '/dev1/port0/line6', ...
        '/dev1/port0/line7', ...
        '/dev1/port1/line0'};
    daqstate.nchannel = numel(daqstate.channels);
    if hasdaq()
        fprintf('initialising new scanner card receive connection\n');
        daqstate.emulate = false;
        warning off daq:Session:onDemandOnlyChannelsAdded
        % from NI_DAQmxCreateTask
        [status, daqstate.hand] = daq.ni.NIDAQmx.DAQmxCreateTask(char(0), uint64(0));
        daq.ni.utility.throwOrWarnOnStatus(status);
        % /from NI_DAQmxCreateTask
        % Add channels
        for this_in = daqstate.channels
            this_in_str = this_in{1};
            % from NI_DAQmxCreateDIChan
            status = daq.ni.NIDAQmx.DAQmxCreateDIChan(daqstate.hand, ...
                this_in_str, char(0), daq.ni.NIDAQmx.DAQmx_Val_ChanForAllLines);
            daq.ni.utility.throwOrWarnOnStatus(status);
            % /from NI_DAQmxCreateDIChan
        end
        % from NI_DAQmxStartTask
        status = daq.ni.NIDAQmx.DAQmxStartTask(daqstate.hand);
        daq.ni.utility.throwOrWarnOnStatus(status);
        % /from NI_DAQmxStartTask
        daqstate.checkfun = @inputSingleScan_lowlevel;
    else
        fprintf(['NI CARD NOT AVAILABLE - entering emulation mode with tr=' ...
            mat2str(tr) '\n']);
        fprintf('if you see this message in the scanner, DO NOT PROCEED\n')
        % struct with a function handle in place of inputSingleScan
        daqstate.emulate = true;
        % dummy
        daqstate.hand.release = @(x)fprintf('reset scansync session.\n');
        daqstate.emulatekeys = [KbName('v'), KbName('b'), KbName('n'), KbName('m'), ...
            KbName('f'), KbName('d'), KbName('s'), KbName('a')];
        daqstate.firstcall = true;
        daqstate.checkfun = @inputSingleScan_emulate;
    end
    % time stamps for the first observed response at each channel
    daqstate.firstresp = NaN([1,daqstate.nchannel]);
    % time stamps for the last *valid* response at each channel
    daqstate.lastresp = NaN([1,daqstate.nchannel]);
    % time stamps for the current response, if valid
    % (why both lastresp and thisresp? To avoid double counting responses)
    daqstate.thisresp = NaN([1,daqstate.nchannel]);
    % previousflags: what was the state on previous call to know whether the new
    % state is a new discrete event
    daqstate.previousflags = zeros(1,daqstate.nchannel);
    % how many discrete channel pulses recorded
    daqstate.nrecorded = zeros(1,daqstate.nchannel);
    % Pulsedur is not needed as dicrete events are counted if they
    % had been Off and ON not with a specific ON time appart.
    % However, in emulation mode the pulsedur for the scanner pulse is
    % still needed.
    daqstate.pulsedur = .006;
end
% /+++++++++++++++++++++++++++

%+++++++++++++++++++++++++++++
% Wait for buttons to be released
%+++++++++++++++++++++++++++++
% % A new option to wait for buttons to be released
if nargin > 2 && strcmpi(opt,'waitrelease')
    daqstate = checkdaq(daqstate);
    if any(daqstate.previousflags(ind))
        disp('waiting to release buttons...')
        
        % wait either fixed time or until released
        while (GetSecs < waituntil) && any(daqstate.previousflags(ind))
            WaitSecs(0.001);
            daqstate = checkdaq(daqstate);
        end
    end
    return;
end
% /+++++++++++++++++++++++++++

%+++++++++++++++++++++++++++++
% Wait for buttons to be pressed
%+++++++++++++++++++++++++++++
% always call once (so we get an update even if waituntil==0)
daqstate = checkdaq(daqstate);
% wait until waituntil time is over or until a button is pressed (up->down
% state)
while (GetSecs < waituntil) && all(isnan(daqstate.thisresp(ind)))
    % avoid choking the CPU, but don't wait so long that we might miss a pulse
    WaitSecs(0.001);
    % checks pulse state for the channels; is the pulse on or not
    daqstate = checkdaq(daqstate);
end
% /+++++++++++++++++++++++++++

%+++++++++++++++++++++++++++++
% Outputs
%+++++++++++++++++++++++++++++
% The button press time.
% This will be NaN if no responses happened, or otherwise not NaN. Note
% that if you entered multiple indices, it will return when the FIRST of these is
% true. So resptime will practically always only have a single non-nan entry
% (barring simultaneous key presses), and to the extent that you have multiple
% entries, they'll all show the same time.
if nargout > 0
    resptime = daqstate.thisresp(ind);
end

% time to estimate the current pulse. only useful for scanner triggers
% (channel 1)
if nargout > 1
    respnumber = floor((GetSecs - daqstate.firstresp(1)) / daqstate.tr);
end

% Struct with internal state
if nargout > 2
    daqret = daqstate;
end

% ========================================================================
% FUNCTIONS
% ========================================================================
% ________________________________________________________________________
%
% Checking and updating channel pulse states
% ________________________________________________________________________
function daqstate = checkdaq(daqstate)
% wipe whatever was in thisresp from the last call
daqstate.thisresp = NaN([1,daqstate.nchannel]);
% time stamp of the check, before any other overhead
timenow = GetSecs;

% =====
% Checks which pulses are ON
% =====
% perilously close to OO here
[daqflags, daqstate] = feval(daqstate.checkfun, daqstate);
% inverted coding
daqflags = ~daqflags; % 1 = 0N, 0 = OFF
% /=====

% =====
% First time registering
% =====
% if this is the first time we observe any of the channels, we need to log the time
% stamp of this into all registers.
newresp = isnan(daqstate.firstresp);
daqstate.firstresp(daqflags & newresp) = timenow;
daqstate.lastresp(daqflags & newresp) = timenow;
daqstate.thisresp(daqflags & newresp) = timenow;
% /=====

% =====
% Record valid presses
% =====
% Discrete events are if the pulse (either scanner or button) was OFF and then ON.

% Check if any channel was OFF on the last call and is ON on the current
valid_pressed = ~daqstate.previousflags & daqflags;
% Such states are regarded as new discrete events
if any(valid_pressed)
    % if so, we need to update lastresp
    daqstate.lastresp(valid_pressed) = timenow;
    % and thisresp
    daqstate.thisresp(valid_pressed) = timenow;
    % and add nrecorded
    daqstate.nrecorded(valid_pressed) = daqstate.nrecorded(valid_pressed)+1;
end
% /=====

% Update previousflags for the next call
daqstate.previousflags = daqflags;

% ________________________________________________________________________
%
% Pulse/button checking in emulation mode
% ________________________________________________________________________
function [flags, daqstate] = inputSingleScan_emulate(daqstate)

% NB inverted coding on NI cards
flags = true(1,daqstate.nchannel);
if daqstate.firstcall
    % make sure we return nothing the very first time we call (on reset). This is
    % important to avoid starting the pulse emulator too early.
    daqstate.firstcall = false;
    return
end

if isnan(daqstate.firstresp(1))
    % record a pulse on first call to start the emulated pulse sequence
    flags(1) = false;
else
    % use the start time to work out whether we should be sending a pulse
    timenow = GetSecs;
    if rem(timenow-daqstate.firstresp(1),daqstate.tr(1))<daqstate.pulsedur(1)
        flags(1) = false;
    end
end

% check for buttons
[keyisdown,~,keyCode] = KbCheck;
if keyisdown
    % flip any keys that match the emulator keys
    respk = find(keyCode);
    [~,ind] = intersect(daqstate.emulatekeys,respk);
    % need to offset by 1 to stay clear of pulse channel
    flags(ind+1) = false;
end

% ________________________________________________________________________
%
% Pulse/button checking in real mode
% ________________________________________________________________________
function [flags, daqstate] = inputSingleScan_lowlevel(daqstate)

% adapted from NI_DAQmxReadDigitalLines
[status,flags,~,~,~] = daq.ni.NIDAQmx.DAQmxReadDigitalLines(...
    daqstate.hand, ... % taskHandle
    int32(1), ... % numSampsPerChan
    double(10), ... % timeout
    uint32(daq.ni.NIDAQmx.DAQmx_Val_GroupByChannel), ... % fillMode; DAQmx_Val_GroupByChannel: Group by channel (non-interleaved)
    uint8(zeros(1,daqstate.nchannel)), ... % arraySizeInBytes
    uint32(daqstate.nchannel), ... % arraySizeInBytes
    int32(0), ... % sampsPerChanRead
    int32(0), ... % numBytesPerSamp
    uint32(0)); % reserved

daq.ni.utility.throwOrWarnOnStatus(status);
% /adapted from NI_DAQmxReadDigitalLines

% ========================================================================
