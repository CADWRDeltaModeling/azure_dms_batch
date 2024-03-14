import sys
import datetime as dt
import argparse

import pyhecdss
import pandas as pd

def build_find_condition(pathname, dfcat):
    '''
    builds find condition based on pathname parts from the catalog dfcat
    '''
    pp = pathname.split('/')
    cond = True
    for p, n in zip(pp[1:4]+pp[5:7], ['A', 'B', 'C', 'E', 'F']):
        if len(p) > 0:
            cond = cond & (dfcat[n] == p)
    twstr = str.strip(pp[4])
    startDateStr = endDateStr = None
    if len(twstr) > 0:
        try:
            startDateStr, endDateStr = pyhecdss.get_start_end_dates(twstr)
        except:
            startDateStr, endDateStr = None, None
    return cond, startDateStr, endDateStr


def findpath(dssh, dfcat, pathname):
    '''
    get data for the open dss handle dssh and catalog dfcat for matching
    pathname parts
    '''
    pathname = pathname.upper()
    cond, startDateStr, endDateStr = build_find_condition(pathname, dfcat)

    plist = dssh.get_pathnames(dfcat[cond])
    for p in plist:
        if p.split('/')[5].startswith('IR-'):
            return dssh.read_its(p, startDateStr, endDateStr)
        else:
            return dssh.read_rts(p, startDateStr, endDateStr)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='extract PTM particle fates')
    parser.add_argument('--start', type=str,required=True,help='start date')
    parser.add_argument('--runno', type=str,required=True,help='run number')
    parser.add_argument('--days', type=int, nargs='+',default=[30,90],help='days from simulation start')
    args = parser.parse_args()

    stn1 = "WHOLE/PTM_GROUP"
    stn2 = "EXPORT_CVP/FLUX"
    stn3 = "EXPORT_CCF/FLUX"
    stn4 = "EXPORT_IF/FLUX"
    stn5 = "EXPORT_SWP/FLUX"
    stn6 = "PAST_MTZ/FLUX"
    stn7 = "DIVERSION_AG/FLUX"
    stn8 = "TO_NBA/FLUX"
    stn9 = "PAST_CHIPPS/FLUX"
    stn10 = "OTH_DIV/PTM_GROUP"
    stn11 = "CLIFTON/PTM_GROUP"
    stn12 = "OLDR_MOUTH/FLUX"
    stn13 = "Columb_Trnr/FLUX"
    stn14 = "Dut_Fal_fish/FLUX"
    stn15 = "MidR_Mouth/FLUX"
    # stn16 = "HONKER_BAY/PTM_GROUP"
    # stn17 = "MID_SUISUNBAY/PTM_GROUP"
    # stn18 = "WEST_SUISUNBAY/PTM_GROUP"
    # stn19 = "SUISUNMARSH/PTM_GROUP"

    path1 = "//"+stn1+"//1HOUR//"
    path2 = "//"+stn2+"//1HOUR//"
    path3 = "//"+stn3+"//1HOUR//"
    path4 = "//"+stn4+"//1HOUR//"
    path5 = "//"+stn5+"//1HOUR//"
    path6 = "//"+stn6+"//1HOUR//"
    path7 = "//"+stn7+"//1HOUR//"
    path8 = "//"+stn8+"//1HOUR//"
    path9 = "//"+stn9+"//1HOUR//"
    path10 = "//"+stn10+"//1HOUR//"
    path11 = "//"+stn11+"//1HOUR//"
    path12 = "//"+stn12+"//1HOUR//"
    path13 = "//"+stn13+"//1HOUR//"
    path14 = "//"+stn14+"//1HOUR//"
    path15 = "//"+stn15+"//1HOUR//"
    # path16 = "//"+stn16+"//1HOUR//"
    # path17 = "//"+stn17+"//1HOUR//"
    # path18 = "//"+stn18+"//1HOUR//"
    # path19 = "//"+stn19+"//1HOUR//"
    fpart=None
    start = args.start
    runno = args.runno
    fn = "ptmout.dss"
    g = fn  # opendss(fn)
    with pyhecdss.DSSFile(fn) as g:
        dfcat = g.read_catalog()
        ref1 = findpath(g, dfcat, path1)
        ref2 = findpath(g, dfcat, path2)
        ref3 = findpath(g, dfcat, path3)
        ref4 = findpath(g, dfcat, path4)
        ref5 = findpath(g, dfcat, path5)
        ref6 = findpath(g, dfcat, path6)
        ref7 = findpath(g, dfcat, path7)
        ref8 = findpath(g, dfcat, path8)
        ref9 = findpath(g, dfcat, path9)
        ref10 = findpath(g, dfcat, path10)
        ref11 = findpath(g, dfcat, path11)
        ref12 = findpath(g, dfcat, path12)
        ref13 = findpath(g, dfcat, path13)
        ref14 = findpath(g, dfcat, path14)
        ref15 = findpath(g, dfcat, path15)
        # ref16 = findpath(g, dfcat,path16)
        # ref17 = findpath(g, dfcat,path17)
        # ref18 = findpath(g, dfcat,path18)
        # ref19 = findpath(g, dfcat,path19)
        if not fpart: # fpart is not defined till after this point
            fpart = ref1.data.columns[0].split('/')[-2]
            print('Detected FPART: ',fpart)
            outfiles={}
            qaoutfiles={}
            for day in args.days:
                outfile = open("ptm_fate_results_"+str(day)+"day.dat", "a")
                outfile.write(str(day)+"-day PTM Output - "+fpart+'\n')
                outfile.write(
                    "SimPeriod,SimLoc,Export_CVP,Export_CCF,Export_IF,Past_MTZ,Past_Chipps,Diversion_Ag,To_NBA"+'\n')
                qaoutfile = open("ptm_fate_results_"+str(day)+"day_qa.dat", "a")
                qaoutfile.write(str(day)+"-day PTM Output - "+fpart+'\n')
                qaoutfile.write(
                    "SimPeriod,SimLoc,Export_CVP,Export_CCF,Export_IF,Past_MTZ,Past_Chipps,Diversion_Ag,To_NBA,Other_Div,In_Delta,Total,East_Chipps,SJR_to_South_Delta"+'\n')
                outfiles[day]=outfile
                qaoutfiles[day]=qaoutfile
    whole_rts = ref1.data.squeeze()
    exp_cvp_rts = ref2.data.squeeze()
    exp_ccf_rts = ref3.data.squeeze()
    exp_if_rts = ref4.data.squeeze()
    exp_swp_rts = ref5.data.squeeze()
    past_mtz_rts = ref6.data.squeeze()
    div_ag_rts = ref7.data.squeeze()
    to_nba_rts = ref8.data.squeeze()
    past_chipps_rts = ref9.data.squeeze()
    oth_div_rts = ref10.data.squeeze()
    clifton_rts = ref11.data.squeeze()
    OLDR_Mouth_rts = ref12.data.squeeze()
    Columb_Trnr_rts = ref13.data.squeeze()
    Dut_Fal_fish_rts = ref14.data.squeeze()
    MidR_Mouth_rts = ref15.data.squeeze()
    # HONKERBAY_rts=ref16.data.squeeze()
    # MID_SUISUNBAY_rts=ref17.data.squeeze()
    # WESTSUISUNBAY_rts=ref18.data.squeeze()
    # SUISUNMARSH_rts=ref19.data.squeeze()
    # past_chipps_rts = HONKERBAY_rts+MID_SUISUNBAY_rts+WESTSUISUNBAY_rts+SUISUNMARSH_rts+past_mtz_rts
    tot_rts = whole_rts+exp_cvp_rts+exp_ccf_rts+past_mtz_rts + \
        div_ag_rts+to_nba_rts+oth_div_rts-clifton_rts+exp_if_rts
    tot_rts_eastchipps = whole_rts+exp_cvp_rts+exp_ccf_rts+past_mtz_rts - \
        past_chipps_rts+div_ag_rts+to_nba_rts+oth_div_rts-clifton_rts+exp_if_rts
    sjr_to_sdelta = OLDR_Mouth_rts+Columb_Trnr_rts+Dut_Fal_fish_rts+MidR_Mouth_rts
    for day in args.days:
        outfile=outfiles[day]
        qaoutfile=qaoutfiles[day]
        tp = pd.to_datetime(start)+pd.Timedelta(int(day), 'D')
        result = start+","+runno+","+str(exp_cvp_rts[tp])+","+str(exp_ccf_rts[tp])+","+str(exp_if_rts[tp])+","+str(
            past_mtz_rts[tp])+","+str(past_chipps_rts[tp])+","+str(div_ag_rts[tp])+","+str(to_nba_rts[tp])
        outfile.write(result+'\n')
        qaresult = result+","+str(oth_div_rts[tp])+","+str(whole_rts[tp])+","+str(
            tot_rts[tp])+","+str(tot_rts_eastchipps[tp])+","+str(sjr_to_sdelta[tp])
        qaoutfile.write(qaresult+'\n')
    for day in args.days:
        outfiles[day].close()
        qaoutfiles[day].close()       
    sys.exit()
# EXPORT_CVP	PAST_MTZ	DIVERSION_AG	EXPORT_SWP	TO_NBA	PAST_CHIPPS  CLIFTON  OTH_DIV

# To Clifton Ct Forebay	To Jones PP	Past Martinez	To Delta Ag	To N Bay Aqdct	To Other Diversions whole

# qa - whole at the end of day 1 + part left delta at the end of day 1
# qa - whole (chan, res) - clif + part left delta at the end of 60 days

# print run_date	p_loc	qa_day1		qa_eosim	var1 ... var9 at the end of 30 days.

# inputs: list of periods, list of loc - 1 to 39
