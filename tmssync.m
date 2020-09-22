function tmssync(ind)

persistent daqstate

if ~exist('ind','var')
    ind = [];
end

if ischar(ind) && strcmpi(ind,'reset')
    % special case to handle re-initialising sync
    if ~isempty(daqstate)
        % TODO - check that this works with new undocumented API
        daqstate.hand.release();
    end
    daqstate = [];
    ind = [];
end


if isempty(daqstate)
    % special initialisation mode
    fprintf('initialising...\n');
    daqstate.channels = {'/dev1/port2/line7'};
    daqstate.nchannel = numel(daqstate.channels);
    if hasdaq()
        fprintf('initialising new scanner card transmit connection\n');
        daqstate.emulate = false;
        warning off daq:Session:onDemandOnlyChannelsAdded
        % from NI_DAQmxCreateTask
        [status, daqstate.hand] = daq.ni.NIDAQmx.DAQmxCreateTask(char(0), uint64(0));
        daq.ni.utility.throwOrWarnOnStatus(status);
        % /from NI_DAQmxCreateTask
        for this_out = daqstate.channels
            this_out_str = this_out{1};
            % from NI_DAQmxCreateDOChan
            status = daq.ni.NIDAQmx.DAQmxCreateDOChan(daqstate.hand, ...
                this_out_str,char(0), daq.ni.NIDAQmx.DAQmx_Val_ChanForAllLines);
            daq.ni.utility.throwOrWarnOnStatus(status);
            % /from NI_DAQmxCreateDOChan
        end
        % from NI_DAQmxStartTask
        status = daq.ni.NIDAQmx.DAQmxStartTask(daqstate.hand);
        daq.ni.utility.throwOrWarnOnStatus(status);
        % /from NI_DAQmxStartTask
        daqstate.sendfun = @sendtrigger_lowlevel;
    else
        fprintf('NI CARD NOT AVAILABLE - entering trigger emulation mode\n')
        fprintf('if you see this message in the scanner, DO NOT PROCEED\n')
        daqstate.emulate = true;
        % dummy 
        daqstate.hand.release = @(x)fprintf('reset scansync session.\n');
        daqstate.sendfun = @sendtrigger_emulate;
    end
    % all setup done
    return
end

% if we make it here, it's trigger time
% recode indices to column vector
triggers = zeros([daqstate.nchannel, 1], 'uint8');
% matlab is fun
assert(all(ind <= daqstate.nchannel), 'index out of range');
triggers(ind) = 1;
daqstate.sendfun(daqstate, triggers);

function sendtrigger_lowlevel(daqstate, triggers)

% from NI_DAQmxWriteDigitalLines
[status, ~] = daq.ni.NI_DAQmxWriteDigitalLines(daqstate.hand, ...
    int32(1), uint32(false), double(10), ...
    uint32(daq.ni.NIDAQmx.DAQmx_Val_GroupByChannel), ...
    triggers, int32(0), uint32(0));
daq.ni.utility.throwOrWarnOnStatus(status);
% /from NI_DAQmxWriteDigitalLines

function sendtrigger_emulate(daqstate, triggers)

% empty for now
