#!/bin/bash
# source this file to get these function shortcuts
function install_dos2unix {
    sudo apt-get update
    sudo apt-get install dos2unix
}

function install_git {
    sudo apt-get update
    sudo apt-get install git
}

function install_miniconda3 {
    wget https://repo.anaconda.com/miniconda/Miniconda3-py37_4.10.3-Linux-x86_64.sh
    chmod +x ./Miniconda3-py37_4.10.3-Linux-x86_64.sh 
    sudo ./Miniconda3-py37_4.10.3-Linux-x86_64.sh -b -p /usr/local/miniconda3
    /usr/local/miniconda3/bin/conda init
    rm ./Miniconda3-py37_4.10.3-Linux-x86_64.sh
}

function install_dmsbatch {
    git clone https://github.com/dwr-psandhu/azure_dms_batch.git
    cd azure_dms_batch
    conda env create -f environment.yml 
    conda activate azure
    pip install --no-deps -e .
    dmsbatch -h
}

function install_azcopy {
    pushd /usr/local/bin
    wget -q https://aka.ms/downloadazcopy-v10-linux -O - | sudo tar zxf - --strip-components 1 --wildcards '*/azcopy'
    sudo chmod 755 /usr/local/bin/azcopy 
    azcopy --version
    popd
}

function install_az {
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    az bicep install
    az --version
}

function install_blobfuse2 {
    sudo wget https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb
    sudo dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb
    sudo apt-get update
    sudo apt-get install blobfuse2
}

# az account set --subscription "DWR BDO"
function az_login {
    az login --use-device-code
}
