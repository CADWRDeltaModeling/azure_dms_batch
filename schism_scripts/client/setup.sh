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
    sudo ./Miniconda3-py37_4.10.3-Linux-x86_64.sh -b
    source ~/.bashrc
    conda install mamba -n base -c conda-forge
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
    cd /usr/local/bin
    wget -q https://aka.ms/downloadazcopy-v10-linux -O - | sudo tar zxf - --strip-components 1 --wildcards '*/azcopy'
    sudo chmod 755 /usr/local/bin/azcopy 
    azcopy --version
}

function install_az {
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    az bicep install
    az --version
}

function install_blobfuse2 {
    sudo wget https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb
    sudo dpkg -i packages-microsoft-prod.deb
    sudo apt-get update
    sudo apt-get install blobfuse2
}

function az_login {
    az login --use-device-code
}
