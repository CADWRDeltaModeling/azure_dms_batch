import sys
import datetime
import argparse

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='extract PTM particle fates')
    parser.add_argument('--start', type=int, nargs=3,required=True,help='start year month day')
    parser.add_argument('--end', type=int, nargs=3,required=True,help='end year month day')
    parser.add_argument('--months', type=int, nargs='+', default=[1, 2, 3, 4, 5, 6,10,11,12], 
                                    help='month numbers 1(JAN) to 12(DEC), e.g. 1 2 3')
    parser.add_argument('--days', type=int, nargs='+',default=[30,90], 
                                                    help='days from simulation start')
    
    args = parser.parse_args()
    print("Processing years",args.start[0]," ", args.end[0], " for days: ",args.days)

    first_read = True
    outfile = open("eco-ptm-survival.csv", "a")
    start = args.start
    end = args.end
    s_d  = datetime.date(start[0], start[1], start[2])
    e_d  = datetime.date(end[0], end[1], end[2])
    d = s_d
    one_day = datetime.timedelta(days=1)
    while (d < e_d+one_day):
        if d.month in args.months:
            c_date = d.strftime("%d%b%Y")
            path_to_dat = "./"+c_date+"/"
            tempfile = open(path_to_dat+"survival-"+d.strftime('%m-%d-%Y')+".csv", "r")
            lines = tempfile.readlines()
            if first_read:
                outfile.write(lines[0])
                first_read = False
            for line in lines[1:]:
                outfile.write(line)
            tempfile.close()
        d = d + one_day
    outfile.close()     
    sys.exit()
