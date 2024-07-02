# call this shell command
# date && tail -100 mirror.out | grep TIME | head -1
# and parse the output to get the date and the time step. The output is of this format from the above command
# Tue May 14 23:09:54 UTC 2024
# TIME STEP=         3936;  TIME=        354240.000000

import os
import sys
import re
import datetime


def get_time_step():
    # get the date and time step from the output of the command
    # get current time from python
    date = datetime.datetime.now()
    time_step = os.popen("tail -100 mirror.out | grep TIME | head -1").read()
    time_step = re.findall(r"\d+", time_step)
    time_step = int(time_step[0])
    return date, time_step


def calculate_speed(date1, time_step1, date2, time_step2, nseconds):
    # calculate the speed
    speed = (time_step2 - time_step1) / nseconds
    return speed


import time


def main():
    # call the function to get the date and time step and calculate the speed
    date1, time_step1 = get_time_step()
    datei, time_stepi = date1, time_step1
    while True:
        # sleep for 5 seconds
        time.sleep(5)
        date2, time_step2 = get_time_step()
        # calculate the speed
        speed = (time_step2 - time_step1) / 5
        print(f"Speed of SCHISM is {speed} time steps per second at {date2}")
        date1, time_step1 = date2, time_step2
        speed_long = (time_step2 - time_stepi) / (date2 - datei).total_seconds()
        print(
            f"Long term Speed of SCHISM is {speed_long} time steps per second since {datei}"
        )


if __name__ == "__main__":
    main()
