#!/bin/bash

# 1. Download the text file from the specified URL
curl -L "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/AdGuardHomeDisallowedIPs.txt" -o AdGuardHomeDisallowedIPs.txt

# 2. Remove any line that starts with an exclamation mark and remove blank spaces between lines
#    in the file AdGuardHomeDisallowedIPs.txt and save the result to a new file called generated.txt
sed '/^!/d; s/^[ \t]*//; s/[ \t]*$//; /^$/d' AdGuardHomeDisallowedIPs.txt > generated2.txt

# 3. Compare generated.txt and generated2.txt and output the lines that are unique to generated2.txt
#    to a new file called new.txt
comm -23 generated2.txt generated.txt > new.txt

#4 cleanup leftover txt files
rm AdGuardHomeDisallowedIPs.txt
rm generated2.txt
