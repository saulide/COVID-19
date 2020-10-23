source ~/.bashrc
export SHELL=/bin/bash
conda env create -n covid-19 -f environment.yml
conda activate covid-19
jupyter lab --ip=0.0.0.0 --allow-root