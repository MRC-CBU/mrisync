function tmssync(ind)

persistent daqstate

if isstr(ind) && strcmpi(ind,'reset')
    % special case to handle re-initialising sync
    if ~isempty(daqstate)
        % TODO - check that this works with new undocumented API
        daqstate.hand.release();
    end
    daqstate = [];
    ind = [];
end

% constants
channels = {'/dev1/port2/line7'};

if isempty(daqstate)
    if hasdaq
        fprintf('initialising new scanner card transmit connection\n');
        daqstate.nchannel = numel(channels);
        daqstate.emulate = false;
        warning off daq:Session:onDemandOnlyChannelsAdded
        % from NI_DAQmxCreateTask
        [status, daqstate.hand] = daq.ni.NIDAQmx.DAQmxCreateTask(char(0), uint64(0));
        daq.ni.utility.throwOrWarnOnStatus(status);
        % /from NI_DAQmxCreateTask
        for this_out = channels
            this_out_str = this_out{1};
            % from NI_DAQmxCreateDOChan
            status = daq.ni.NIDAQmx.DAQmxCreateDOChan(daqstate.hand, ...
                this_out_str,char(0), daq.ni.NIDAQmx.DAQmx_Val_ChanForAllLines);
            daq.ni.utility.throwOrWarnOnStatus(status);
            % /from NI_DAQmxCreateDOChan
        end
        status = daq.ni.NIDAQmx.DAQmxStartTask(daqstate.hand);
        daq.ni.utility.throwOrWarnOnStatus(status);
    else
        fprintf(['NI CARD NOT AVAILABLE - entering emulation mode with tr=' ...
            mat2str(tr) '\n']);
        fprintf('if you see this message in the scanner, DO NOT PROCEED\n')
        % struct with a function handle in place of inputSingleScan
        daqstate = daqemulator(tr);
    end
