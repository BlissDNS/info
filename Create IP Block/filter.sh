#!/bin/bash

# 1. Download the AGH IP blocklist from DandelionSprout
curl -L "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/AdGuardHomeDisallowedIPs.txt" -o AdGuardHomeDisallowedIPs.txt

# 2. Remove any line that starts with an exclamation mark and remove blank spaces between lines
#    in the file AdGuardHomeDisallowedIPs.txt and save the result to a new file called generated.txt
sed '/^!/d; s/^[ \t]*//; s/[ \t]*$//; /^$/d' AdGuardHomeDisallowedIPs.txt > generated.txt

# 3. Remove the original AdGuardHomeDisallowedIPs.txt file
rm AdGuardHomeDisallowedIPs.txt
