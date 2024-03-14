import sys
import datetime as dt
import argparse

MONTH_MAP=dict(zip(range(1,13),['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC']))
#MONTH_MAP=dict(zip(range(1,13),['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='extract PTM particle fates')
    parser.add_argument('--start', type=int, nargs=3,required=True,help='start year month day')
    parser.add_argument('--end', type=int, nargs=3,required=True,help='end year month day')
    parser.add_argument('--months', type=int, nargs='+', default=[1, 2, 3, 4, 5, 6], 
                                    help='month numbers 1(JAN) to 12(DEC), e.g. 1 2 3')
    parser.add_argument('--days', type=int, nargs='+',default=[30,90], 
                                                    help='days from simulation start')
    
    args = parser.parse_args()
    print("Processing years",args.start[0]," ", args.end[0], " for days: ",args.days)
    for day in args.days:
        first_read = True
        outfile = open("ptm_fate_results_"+str(day)+"day.dat", "a")
        qaoutfile = open("ptm_fate_results_"+str(day)+"day_qa.dat", "a")
        for yr in range(args.start[0],args.end[0]+1):
            for e in [MONTH_MAP[i] for i in args.months]:
                for i in range(1, 40):
                    start = "01"+e+str(yr)
                    path_to_dat = "./"+start+"/"+str(i)+"/"
                    tempfile = open(path_to_dat+"ptm_fate_results_"+str(day)+"day.dat", "r")
                    qatempfile = open(path_to_dat+"ptm_fate_results_"+str(day)+"day_qa.dat", "r")
                    lines = tempfile.readlines()
                    qalines = qatempfile.readlines()
                    if first_read:
                        outfile.write(lines[0])
                        outfile.write(lines[1])
                        qaoutfile.write(qalines[0])
                        qaoutfile.write(qalines[1])
                        first_read = False
                    for line in lines[2:]:
                        outfile.write(line)
                    for qaline in qalines[2:]:
                        qaoutfile.write(qaline)
                    tempfile.close()
                    qatempfile.close()
        outfile.close()
        qaoutfile.close()
      
    sys.exit()
# EXPORT_CVP	PAST_MTZ	DIVERSION_AG	EXPORT_SWP	TO_NBA	PAST_CHIPPS  CLIFTON  OTH_DIV

# To Clifton Ct Forebay	To Jones PP	Past Martinez	To Delta Ag	To N Bay Aqdct	To Other Diversions whole

# qa - whole at the end of day 1 + part left delta at the end of day 1
# qa - whole (chan, res) - clif + part left delta at the end of 60 days

# print run_date	p_loc	qa_day1		qa_eosim	var1 ... var9 at the end of 30 days.

# inputs: list of periods, list of loc - 1 to 39
